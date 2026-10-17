import SwiftUI
import BeakrNetCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import AudioToolbox
import Network
import NetworkExtension
import UIKit
#endif

#if os(macOS)
private enum MacNavigationColumn: Hashable {
    case content
}
#endif

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MessageComposerModel
    @State private var bootstrap: NodeBootstrapModel
#if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @AppStorage("net.beakr.settings.selectedTab") private var selectedSettingsTab = BeakrSettingsTab.networks.rawValue
    @AppStorage("net.beakr.settings.networkPane") private var selectedNetworkSettingsPane = NetworkSettingsPane.information.rawValue
    @AppStorage("net.beakr.networkManager.selectedNetworkID") private var persistedNetworkSettingsID = ""
    @State private var selectedSidebarRoute: MacSidebarRoute?
    @State private var selectedDetailRoute: MacDetailRoute?
    @State private var showingContactsDialog = false
    @State private var showingComposerDialog = false
    @State private var contextPendingDeletion: ContextSummary?
    @State private var devicePendingForget: MacMemberDetail?
    @State private var confirmingHistoryDeletion = false
    @State private var confirmingQueuedDeletion = false
    @State private var macMessageSearchText = ""
    @State private var restoreMacContentFocusOnActivation = false
    @FocusState private var focusedMacColumn: MacNavigationColumn?
#endif

    init() {
        let inbox = ApplicationMessageInbox()
        let deliveryUpdates = ApplicationDeliveryUpdates()
        let lanRuntime = ApplicationLANRuntimeManager(
            inbox: inbox,
            deliveryUpdates: deliveryUpdates
        )
        _model = State(initialValue: MessageComposerModel(
            messagingService: lanRuntime,
            inbox: inbox,
            deliveryUpdates: deliveryUpdates
        ))
        _bootstrap = State(initialValue: NodeBootstrapModel(lanRuntimeManager: lanRuntime))
    }

    init(model: MessageComposerModel) {
        _model = State(initialValue: model)
        _bootstrap = State(initialValue: NodeBootstrapModel())
    }

    init(model: MessageComposerModel, bootstrap: NodeBootstrapModel) {
        _model = State(initialValue: model)
        _bootstrap = State(initialValue: bootstrap)
    }

    var body: some View {
#if os(macOS)
        desktopContent
            .onOpenURL(perform: handleInvitationURL)
            .onChange(of: model.receivedFeedbackSequence) { _, _ in
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
#else
        IOSMailRootView(model: model, bootstrap: bootstrap)
            .sensoryFeedback(.success, trigger: model.receivedFeedbackSequence)
            .onChange(of: model.receivedFeedbackSequence) { _, _ in
                AudioServicesPlaySystemSound(1007)
            }
            .task {
                await bootstrap.start()
            }
            .task {
                await model.observeIncomingMessages()
            }
            .task {
                await model.observeDeliveryUpdates()
            }
            .task {
                await model.observeReadReceipts()
            }
            .task {
                await model.observeMailboxPersistenceFailures()
            }
            .task(id: bootstrap.state) {
                guard bootstrap.state == .ready else { return }
                while !Task.isCancelled {
                    await bootstrap.refreshNetworkMembers()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .task {
                var previousAvailability: Bool?
                for await isAvailable in WiFiPathObserver().updates {
                    if let previousAvailability,
                       previousAvailability != isAvailable,
                       scenePhase == .active {
                        await bootstrap.reconnectActiveNetwork()
                    }
                    previousAvailability = isAvailable
                }
            }
            .onChange(of: bootstrap.networkMembers, initial: true) { _, members in
                model.synchronizeRecipients(with: members)
            }
            .onChange(of: bootstrap.onlineMemberIDs, initial: true) { _, ids in
                model.synchronizeOnlineRecipients(with: ids)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    Task { await bootstrap.applicationDidEnterBackground() }
                } else if phase == .active {
                    Task { await bootstrap.applicationBecameActive(forceRestart: true) }
                }
            }
            .onOpenURL(perform: handleInvitationURL)
#endif
    }

    private func handleInvitationURL(_ url: URL) {
        guard let invitation = InvitationLink.invitation(from: url) else { return }
        bootstrap.joinInvitationJSON = invitation
        Task { await bootstrap.joinNetwork() }
    }

#if os(macOS)
    private var desktopContent: some View {
        NavigationSplitView {
            mailboxSidebar
        } content: {
            messageList
                .toolbar {
                    if selectedSidebarRoute?.mailboxSelection != nil {
                        MessageListToolbar(
                            refresh: { Task { await refreshMacNetworks() } },
                            showContacts: { showingContactsDialog = true },
                            requestHistoryDeletion: { confirmingHistoryDeletion = true },
                            requestQueuedDeletion: { confirmingQueuedDeletion = true },
                            canDeleteHistory: !model.incomingMessages.isEmpty || model.outgoingMessages.contains {
                                $0.state == .sent || $0.state == .delivered || $0.state == .failed
                            },
                            canDeleteQueuedMessages: model.outgoingMessages.contains {
                                $0.state == .queued || $0.state == .sending
                            }
                        )
                    }
                }
        } detail: {
            messageDetail
                .toolbar {
                    switch selectedDetailRoute {
                    case .message:
                        MessageBodyToolbar(
                            compose: { showingComposerDialog = true },
                            reply: replyToSelectedMessage,
                            replyAll: replyToSelectedMessage,
                            forward: forwardSelectedMessage,
                            canReply: canReplyToSelectedMessage,
                            canForward: canForwardSelectedMessage
                        )
                    case .device:
                        DevicePropertiesToolbar(
                            forgetDevice: { devicePendingForget = selectedDevice },
                            canForgetDevice: selectedDevice.map {
                                !$0.isLocalDevice && !$0.isOnline
                            } ?? false
                        )
                    case nil:
                        EmptyDetailToolbar()
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .defaultFocus($focusedMacColumn, .content)
        .frame(minWidth: 800, minHeight: 170)
        .sheet(isPresented: $showingContactsDialog) {
            contactsDialog
        }
        .sheet(isPresented: $showingComposerDialog) {
            composerDialog
        }
        .confirmationDialog(
            "Delete Context and All Data?",
            isPresented: Binding(
                get: { contextPendingDeletion != nil },
                set: { if !$0 { contextPendingDeletion = nil } }
            ),
            presenting: contextPendingDeletion
        ) { context in
            Button("Delete \(context.displayName) and Data", role: .destructive) {
                contextPendingDeletion = nil
                if selectedMailbox?.contextID == context.id {
                    selectedSidebarRoute = nil
                    selectedDetailRoute = nil
                }
                Task { await bootstrap.deleteArchivedContext(context.id) }
            }
            Button("Keep Context", role: .cancel) {}
        } message: { context in
            Text("This permanently deletes every locally stored message, mailbox setting, and data store belonging to \(context.displayName). This cannot be undone and reconnecting later will create a new Context.")
        }
        .confirmationDialog("Delete Message History?", isPresented: $confirmingHistoryDeletion) {
            Button("Delete Message History", role: .destructive) {
                Task { await model.deleteMessageHistory() }
            }
        } message: {
            Text("Received, delivered, and failed messages will be deleted. Queued messages will be preserved.")
        }
        .confirmationDialog("Delete Queued Messages?", isPresented: $confirmingQueuedDeletion) {
            Button("Delete Queued Messages", role: .destructive) {
                Task { await model.deleteQueuedMessages() }
            }
        } message: {
            Text("Queued sends will be cancelled and removed. Delivered message history will be preserved.")
        }
        .confirmationDialog(
            "Forget Remembered Device?",
            isPresented: Binding(
                get: { devicePendingForget != nil },
                set: { if !$0 { devicePendingForget = nil } }
            ),
            presenting: devicePendingForget
        ) { device in
            Button("Forget \(device.displayName)", role: .destructive) {
                devicePendingForget = nil
                Task { await bootstrap.forgetRememberedDevice(device.deviceID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("This removes the cached name and last-seen information for \(device.displayName). Message history is preserved, and the device remains a network member and may reappear when it reconnects.")
        }
        .task { await bootstrap.start() }
        .task { await model.observeIncomingMessages() }
        .task { await model.observeDeliveryUpdates() }
        .task { await model.observeReadReceipts() }
        .task { await model.observeMailboxPersistenceFailures() }
        .task(id: bootstrap.state) {
            guard bootstrap.state == .ready else { return }
            while !Task.isCancelled {
                await bootstrap.refreshNetworkMembers()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: bootstrap.networkMembers, initial: true) { _, members in
            model.synchronizeRecipients(with: members)
        }
        .onChange(of: bootstrap.onlineMemberIDs, initial: true) { _, ids in
            model.synchronizeOnlineRecipients(with: ids)
        }
        .onChange(of: bootstrap.networks, initial: true) { _, networks in
            guard selectedSidebarRoute == nil, let activeNetwork = networks.first(where: \.isActive) else { return }
            selectedSidebarRoute = .mailbox(MailboxSelection(networkID: activeNetwork.id, mailbox: .inbox))
        }
        .onChange(of: selectedSidebarRoute) { _, route in
            selectedDetailRoute = nil
            Task { @MainActor in
                await Task.yield()
                focusedMacColumn = .content
            }
            guard let networkID = route?.mailboxSelection?.networkID,
                  !bootstrap.networks.contains(where: { $0.id == networkID && $0.isActive }) else { return }
            Task { await bootstrap.switchNetwork(to: networkID) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive {
                restoreMacContentFocusOnActivation = focusedMacColumn == .content
            } else if phase == .background {
                restoreMacContentFocusOnActivation = restoreMacContentFocusOnActivation
                    || focusedMacColumn == .content
                Task { await bootstrap.applicationDidEnterBackground() }
            } else if phase == .active {
                Task { await bootstrap.applicationBecameActive() }
                if restoreMacContentFocusOnActivation, selectedDetailRoute != nil {
                    Task { @MainActor in
                        await Task.yield()
                        focusedMacColumn = .content
                        restoreMacContentFocusOnActivation = false
                    }
                }
            }
        }
    }

    private var orderedMacNetworks: [NetworkSummary] {
        guard let activeIndex = bootstrap.networks.firstIndex(where: \.isActive) else {
            return bootstrap.networks
        }

        var orderedNetworks = bootstrap.networks
        let activeNetwork = orderedNetworks.remove(at: activeIndex)
        orderedNetworks.insert(activeNetwork, at: 0)
        return orderedNetworks
    }

    private var selectedMailbox: MailboxSelection? {
        selectedSidebarRoute?.mailboxSelection
    }

    private var selectedMessage: MailMessageSelection? {
        selectedDetailRoute?.messageSelection
    }

    private var selectedDevice: MacMemberDetail? {
        guard case .device(let networkID, let deviceID) = selectedDetailRoute else { return nil }
        return macMemberDirectory.member(networkID: networkID, deviceID: deviceID)
    }

    private var mailboxSidebar: some View {
        MacNetworkSidebar(
            model: model,
            bootstrap: bootstrap,
            orderedNetworks: orderedMacNetworks,
            selection: $selectedSidebarRoute,
            requestContextDeletion: { contextPendingDeletion = $0 },
            openNetworkSettings: openMacNetworkSettings
        )
    }

    private func openMacNetworkSettings(_ network: NetworkSummary) {
        persistedNetworkSettingsID = network.id.rawValue.uuidString
        selectedSettingsTab = BeakrSettingsTab.networks.rawValue
        selectedNetworkSettingsPane = NetworkSettingsPane.information.rawValue
        openSettings()
    }

    private func refreshMacNetworks() async {
        await bootstrap.reconnectActiveNetwork()
        await bootstrap.refreshNetworkMembers()
    }

    private var messageList: some View {
        MacContextList(
            sidebarRoute: selectedSidebarRoute,
            detailRoute: $selectedDetailRoute,
            incomingMessages: selectedIncomingMessages,
            outgoingMessages: selectedOutgoingMessages,
            memberDirectory: macMemberDirectory,
            focus: $focusedMacColumn,
            displayName: selectedDisplayName,
            isRead: selectedIsRead,
            isFlagged: selectedIsFlagged
        )
    }

    private var messageDetail: some View {
        MacDetailContent(
            route: selectedDetailRoute,
            incomingMessages: selectedIncomingMessages,
            outgoingMessages: selectedOutgoingMessages,
            memberDirectory: macMemberDirectory,
            messageSearchText: $macMessageSearchText,
            displayName: selectedDisplayName,
            shouldMarkIncomingAsRead: selectedMailbox?.contextID == nil,
            openIncomingMessage: model.openIncomingMessage
        )
    }

    private var canReplyToSelectedMessage: Bool {
        guard selectedMailbox?.contextID == nil,
              case .incoming(let id) = selectedMessage,
              let source = selectedIncomingMessages.first(where: { $0.id == id })?.source else {
            return false
        }
        return model.isAddressable(source)
    }

    private var canForwardSelectedMessage: Bool {
        guard selectedMailbox?.contextID == nil, let selectedMessage else { return false }
        switch selectedMessage {
        case .incoming(let id):
            return selectedIncomingMessages.contains(where: { $0.id == id })
        case .outgoing(let id):
            return selectedOutgoingMessages.contains(where: { $0.id == id })
        }
    }

    private func replyToSelectedMessage() {
        guard case .incoming(let id) = selectedMessage,
              let source = selectedIncomingMessages.first(where: { $0.id == id })?.source,
              model.isAddressable(source) else { return }
        model.prepareReply(to: source)
        showingComposerDialog = true
    }

    private func forwardSelectedMessage() {
        guard let selectedMessage else { return }
        let body: String?
        switch selectedMessage {
        case .incoming(let id):
            body = selectedIncomingMessages.first(where: { $0.id == id })?.body
        case .outgoing(let id):
            body = selectedOutgoingMessages.first(where: { $0.id == id })?.body
        }
        guard let body else { return }
        model.prepareForward(body: body)
        showingComposerDialog = true
    }

    private var selectedIncomingMessages: [IncomingMessage] {
        guard let contextID = selectedMailbox?.contextID else { return model.incomingMessages }
        return bootstrap.archivedIncomingMessages[contextID] ?? []
    }

    private var selectedOutgoingMessages: [OutgoingMessage] {
        guard let contextID = selectedMailbox?.contextID,
              let metadata = bootstrap.archivedMailboxMetadata[contextID] else {
            return model.outgoingMessages
        }
        return metadata.outgoingMessages
    }

    private var macMemberDirectory: MacMemberDirectorySnapshot {
        MacMemberDirectorySnapshot(
            networks: bootstrap.networks,
            localDeviceName: bootstrap.deviceDisplayName,
            localDeviceID: bootstrap.nodeID,
            activeNetworkMembers: bootstrap.networkMembers,
            onlineMemberIDs: bootstrap.onlineMemberIDs
        )
    }

    private func selectedDisplayName(for address: UUID) -> String {
        guard let contextID = selectedMailbox?.contextID else {
            return model.displayName(for: address)
        }
        return bootstrap.archivedMailboxMetadata[contextID]?
            .recipients.first(where: { $0.id == address })?.name ?? address.uuidString
    }

    private func selectedIsRead(_ messageID: UUID) -> Bool {
        guard let contextID = selectedMailbox?.contextID else { return model.isRead(messageID) }
        return bootstrap.archivedMailboxMetadata[contextID]?.readMessageIDs.contains(messageID) ?? false
    }

    private func selectedIsFlagged(_ messageID: UUID) -> Bool {
        guard let contextID = selectedMailbox?.contextID else { return model.isFlagged(messageID) }
        return bootstrap.archivedMailboxMetadata[contextID]?.flaggedMessageIDs.contains(messageID) ?? false
    }

    private var contactsDialog: some View {
        NavigationStack {
            Form {
                RecipientManagementSection(
                    recipients: model.recipients,
                    add: model.addRecipient,
                    rename: model.renameRecipient,
                    remove: model.removeRecipient
                )
            }
            .formStyle(.grouped)
            .navigationTitle("Contacts")
            .toolbar {
                Button("Done") { showingContactsDialog = false }
            }
        }
        .frame(minWidth: 540, minHeight: 480)
    }

    private var composerDialog: some View {
        NavigationStack {
            Form {
                MessageComposerSection(
                    recipients: model.addressableRecipients,
                    onlineRecipientIDs: model.onlineRecipientIDs,
                    destinationID: $model.destinationID,
                    messageText: $model.messageText,
                    canSend: model.canSend,
                    send: {
                        Task {
                            await model.send()
                            if model.messageText.isEmpty {
                                showingComposerDialog = false
                                if let activeNetwork = bootstrap.networks.first(where: \.isActive) {
                                    selectedSidebarRoute = .mailbox(
                                        MailboxSelection(networkID: activeNetwork.id, mailbox: .outbox)
                                    )
                                }
                            }
                        }
                    }
                )
            }
            .formStyle(.grouped)
            .navigationTitle("New Message")
            .toolbar {
                Button("Cancel") { showingComposerDialog = false }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

#endif
}

#if os(macOS)
@MainActor
private struct MacNetworkSidebar: View {
    let model: MessageComposerModel
    let bootstrap: NodeBootstrapModel
    let orderedNetworks: [NetworkSummary]
    @Binding var selection: MacSidebarRoute?
    let requestContextDeletion: (ContextSummary) -> Void
    let openNetworkSettings: (NetworkSummary) -> Void

    private var activeNetwork: NetworkSummary? {
        orderedNetworks.first(where: \.isActive)
    }

    private var memberDirectory: MacMemberDirectorySnapshot {
        MacMemberDirectorySnapshot(
            networks: orderedNetworks,
            localDeviceName: bootstrap.deviceDisplayName,
            localDeviceID: bootstrap.nodeID,
            activeNetworkMembers: bootstrap.networkMembers,
            onlineMemberIDs: bootstrap.onlineMemberIDs
        )
    }

    var body: some View {
        List(selection: $selection) {
            Section("Networks") {
                ForEach(orderedNetworks) { network in
                    MacNetworkOverviewSection(
                        network: network,
                        incomingCount: network.isActive ? model.incomingMessages.count : 0,
                        outgoingCount: network.isActive ? model.outgoingMessages.count : 0,
                        onlineMemberCount: memberDirectory.members(
                            networkID: network.id,
                            availability: .online
                        ).count,
                        offlineMemberCount: memberDirectory.members(
                            networkID: network.id,
                            availability: .offline
                        ).count,
                        activeConnectivity: bootstrap.activeNetworkConnectivity,
                        membersAreAvailable: network.isActive
                    )
                }
            }

            if !bootstrap.archivedContexts.isEmpty {
                ForEach(bootstrap.archivedContexts) { context in
                    Section {
                        Label("Inbox", systemImage: "tray")
                            .font(.caption)
                            .badge(bootstrap.archivedIncomingMessages[context.id]?.count ?? 0)
                            .tag(MacSidebarRoute.mailbox(
                                MailboxSelection(contextID: context.id, mailbox: .inbox)
                            ))
                        Label("Outbox", systemImage: "paperplane")
                            .font(.caption)
                            .badge(bootstrap.archivedMailboxMetadata[context.id]?.outgoingMessages.count ?? 0)
                            .tag(MacSidebarRoute.mailbox(
                                MailboxSelection(contextID: context.id, mailbox: .outbox)
                            ))
                    } header: {
                        Label(context.displayName, systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                            .contextMenu {
                                Button("Delete Context and Data", systemImage: "trash", role: .destructive) {
                                    requestContextDeletion(context)
                                }
                            }
                    }
                }
            }

            if let failure = bootstrap.profileRegistryLoadFailure {
                ContentUnavailableView(
                    "Network Data Could Not Be Loaded",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Your saved network data was preserved. Beakr could not read it: \(failure)")
                )
            } else if bootstrap.networks.isEmpty && bootstrap.archivedContexts.isEmpty {
                ContentUnavailableView(
                    "No Network",
                    systemImage: "network.slash",
                    description: Text("Use the Networks toolbar button to create or join a network.")
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Beakr")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let activeNetwork else { return }
                    openNetworkSettings(activeNetwork)
                } label: {
                    MacNetworkStatusIcon(
                        connectivity: bootstrap.activeNetworkConnectivity,
                        systemImage: activeNetwork?.canManageNetwork == true
                            ? "network.badge.shield.half.filled"
                            : "network"
                    )
                    .font(.body)
                }
                .tint(bootstrap.activeNetworkConnectivity.networkTintColor)
                .disabled(activeNetwork == nil)
                .accessibilityLabel("Active Network")
                .accessibilityValue(bootstrap.activeNetworkStatusTitle)
                .help(
                    activeNetwork.map {
                        "Open settings for \($0.displayName) — \(bootstrap.activeNetworkStatusTitle)"
                    } ?? "No active network"
                )
            }
        }
    }
}

private struct MacContextList: View {
    let sidebarRoute: MacSidebarRoute?
    @Binding var detailRoute: MacDetailRoute?
    let incomingMessages: [IncomingMessage]
    let outgoingMessages: [OutgoingMessage]
    let memberDirectory: MacMemberDirectorySnapshot
    let focus: FocusState<MacNavigationColumn?>.Binding
    let displayName: (UUID) -> String
    let isRead: (UUID) -> Bool
    let isFlagged: (UUID) -> Bool

    @ViewBuilder
    var body: some View {
        switch sidebarRoute {
        case .mailbox(let mailbox):
            MacMessageList(
                mailbox: mailbox,
                detailRoute: $detailRoute,
                incomingMessages: incomingMessages,
                outgoingMessages: outgoingMessages,
                focus: focus,
                displayName: displayName,
                isRead: isRead,
                isFlagged: isFlagged
            )
        case .members(let networkID, let availability):
            MacMemberList(
                members: memberDirectory.members(
                    networkID: networkID,
                    availability: availability
                ),
                availability: availability,
                focus: focus,
                detailRoute: $detailRoute
            )
        case nil:
            ContentUnavailableView("Select a Mailbox", systemImage: "sidebar.left")
        }
    }
}

private struct MacMessageList: View {
    let mailbox: MailboxSelection
    @Binding var detailRoute: MacDetailRoute?
    let incomingMessages: [IncomingMessage]
    let outgoingMessages: [OutgoingMessage]
    let focus: FocusState<MacNavigationColumn?>.Binding
    let displayName: (UUID) -> String
    let isRead: (UUID) -> Bool
    let isFlagged: (UUID) -> Bool
    @ScaledMetric(relativeTo: .body) private var messageRowMinimumHeight = 64

    var body: some View {
        let messageCount = mailbox.mailbox == .inbox
            ? incomingMessages.count
            : outgoingMessages.count

        List(selection: $detailRoute) {
            switch mailbox.mailbox {
            case .inbox:
                ForEach(incomingMessages) { message in
                    IncomingMailRow(
                        sender: message.source.map(displayName) ?? "Unknown Sender",
                        subject: message.subject,
                        preview: message.preview,
                        receivedAt: message.receivedAt,
                        isRead: isRead(message.id),
                        isFlagged: isFlagged(message.id)
                    )
                    .tag(MacDetailRoute.message(.incoming(message.id)))
                }
            case .outbox:
                ForEach(outgoingMessages) { message in
                    OutgoingMailRow(
                        recipient: displayName(message.destination),
                        messageBody: message.body,
                        state: message.state,
                        deliveredAt: message.deliveredAt,
                        openedAt: message.openedAt
                    )
                    .tag(MacDetailRoute.message(.outgoing(message.id)))
                }
            }
        }
        .environment(\.defaultMinListRowHeight, messageRowMinimumHeight)
        .focused(focus, equals: .content)
        .listStyle(.inset)
        .overlay {
            if mailbox.mailbox == .inbox && incomingMessages.isEmpty {
                MacColumnEmptyState("No Items", systemImage: "tray")
            } else if mailbox.mailbox == .outbox && outgoingMessages.isEmpty {
                MacColumnEmptyState("No Items", systemImage: "paperplane")
            }
        }
        .navigationTitle(Text(mailbox.mailbox.title))
        .navigationSubtitle(messageCount == 1 ? "1 message" : "\(messageCount) messages")
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
    }
}

private struct MacMemberList: View {
    let members: [MacMemberDetail]
    let availability: MacMemberAvailability
    let focus: FocusState<MacNavigationColumn?>.Binding
    @Binding var detailRoute: MacDetailRoute?

    var body: some View {
        List(members, selection: $detailRoute) { member in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(member.isOnline ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(member.displayName)
                        .fontWeight(.semibold)
                }

                Text(member.isLocalDevice ? "This Device" : member.deviceID.uuidString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !member.isOnline, let lastSeen = member.lastSeen {
                    Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tag(MacDetailRoute.device(member.networkID, member.deviceID))
            .accessibilityElement(children: .combine)
            .accessibilityValue(member.isOnline ? "Online" : "Offline")
        }
        .focused(focus, equals: .content)
        .listStyle(.inset)
        .overlay {
            if members.isEmpty {
                MacColumnEmptyState(
                    availability == .online ? "No Online Devices" : "No Offline Devices",
                    systemImage: availability == .online ? "network" : "network.slash"
                )
            }
        }
        .navigationTitle(availability.title)
        .navigationSubtitle(members.count == 1 ? "1 device" : "\(members.count) devices")
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
    }
}

private struct MacColumnEmptyState: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)

            Text(title)
                .font(.title2)
                .fontWeight(.regular)
        }
        .foregroundStyle(.secondary)
    }
}

private struct MacDetailContent: View {
    let route: MacDetailRoute?
    let incomingMessages: [IncomingMessage]
    let outgoingMessages: [OutgoingMessage]
    let memberDirectory: MacMemberDirectorySnapshot
    @Binding var messageSearchText: String
    let displayName: (UUID) -> String
    let shouldMarkIncomingAsRead: Bool
    let openIncomingMessage: (IncomingMessage) async -> Void

    @ViewBuilder
    var body: some View {
        switch route {
        case .message(let selection):
            MacMessageDetail(
                selection: selection,
                incomingMessages: incomingMessages,
                outgoingMessages: outgoingMessages,
                displayName: displayName,
                shouldMarkIncomingAsRead: shouldMarkIncomingAsRead,
                openIncomingMessage: openIncomingMessage
            )
            .searchable(
                text: $messageSearchText,
                placement: .toolbar,
                prompt: "Search"
            )
        case .device(let networkID, let deviceID):
            if let member = memberDirectory.member(networkID: networkID, deviceID: deviceID) {
                MacDeviceProperties(member: member)
            } else {
                ContentUnavailableView("Device Unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            }
        case nil:
            Text("No Item Selected")
                .font(.title2)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MacMessageDetail: View {
    let selection: MailMessageSelection
    let incomingMessages: [IncomingMessage]
    let outgoingMessages: [OutgoingMessage]
    let displayName: (UUID) -> String
    let shouldMarkIncomingAsRead: Bool
    let openIncomingMessage: (IncomingMessage) async -> Void

    @ViewBuilder
    var body: some View {
        switch selection {
        case .incoming(let id):
            if let message = incomingMessages.first(where: { $0.id == id }) {
                MailMessageDetail(
                    heading: message.source.map(displayName) ?? "Unknown Sender",
                    address: message.source?.uuidString,
                    metadata: message.receivedAt.formatted(date: .abbreviated, time: .shortened),
                    messageBody: message.body
                )
                .task {
                    if shouldMarkIncomingAsRead {
                        await openIncomingMessage(message)
                    }
                }
            } else {
                ContentUnavailableView("Message Unavailable", systemImage: "exclamationmark.bubble")
            }
        case .outgoing(let id):
            if let message = outgoingMessages.first(where: { $0.id == id }) {
                MailMessageDetail(
                    heading: displayName(message.destination),
                    address: message.destination.uuidString,
                    metadata: message.state.detailTitle,
                    messageBody: message.body
                )
            } else {
                ContentUnavailableView("Message Unavailable", systemImage: "exclamationmark.bubble")
            }
        }
    }
}

private struct MessageListToolbar: ToolbarContent {
    let refresh: () -> Void
    let showContacts: () -> Void
    let requestHistoryDeletion: () -> Void
    let requestQueuedDeletion: () -> Void
    let canDeleteHistory: Bool
    let canDeleteQueuedMessages: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            ControlGroup {
                Button("Filter", systemImage: "line.3.horizontal.decrease") {}
                    .help("Message filtering is not yet available")

                Menu("More", systemImage: "ellipsis") {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                        .keyboardShortcut("r", modifiers: .command)

                    Button("Contacts", systemImage: "person.2", action: showContacts)

                    Divider()

                    Button(
                        "Delete Message History",
                        systemImage: "trash",
                        role: .destructive,
                        action: requestHistoryDeletion
                    )
                    .disabled(!canDeleteHistory)

                    Button(
                        "Delete Queued Messages",
                        systemImage: "xmark.circle",
                        role: .destructive,
                        action: requestQueuedDeletion
                    )
                    .disabled(!canDeleteQueuedMessages)
                }
                .help("More mailbox actions")
            }
            .controlGroupStyle(.navigation)
        }
    }
}

private struct MessageBodyToolbar: ToolbarContent {
    let compose: () -> Void
    let reply: () -> Void
    let replyAll: () -> Void
    let forward: () -> Void
    let canReply: Bool
    let canForward: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button("Compose", systemImage: "square.and.pencil", action: compose)
                .keyboardShortcut("n", modifiers: .command)
                .help("Compose a new message")
        }
        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            ControlGroup {
                Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
                    .disabled(!canReply)
                    .help("Reply")

                Button("Reply All", systemImage: "arrowshape.turn.up.left.2", action: replyAll)
                    .disabled(!canReply)
                    .help("Reply All")

                Button("Forward", systemImage: "arrowshape.turn.up.right", action: forward)
                    .disabled(!canForward)
                    .help("Forward")
            }
            .controlGroupStyle(.navigation)
        }
        .sharedBackgroundVisibility(.visible)
        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            ControlGroup {
                Button("Move", systemImage: "archivebox") {}
                    .disabled(true)
                    .help("Move is not yet available")

                Button("Delete", systemImage: "trash") {}
                    .disabled(true)
                    .help("Delete is not yet available")

                Button("Move to Junk", systemImage: "xmark.bin") {}
                    .disabled(true)
                    .help("Move to Junk is not yet available")
            }
            .controlGroupStyle(.navigation)
        }
        .sharedBackgroundVisibility(.visible)
        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            Menu("Move to Folder", systemImage: "folder") {
                Text("Folder moves are not yet available")
            }
            .disabled(true)
            .help("Move to Folder is not yet available")
        }
        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            Menu("Flag", systemImage: "flag.fill") {
                Text("Flag colors are not yet available")
            }
            .disabled(true)
            .help("Flagging is not yet available")
        }
    }
}

private struct DevicePropertiesToolbar: ToolbarContent {
    let forgetDevice: () -> Void
    let canForgetDevice: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button("Forget Device", systemImage: "person.crop.circle.badge.minus", action: forgetDevice)
                .disabled(!canForgetDevice)
                .help(canForgetDevice ? "Forget cached information for this device" : "A device must be offline before it can be forgotten")
        }
    }
}

private struct EmptyDetailToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            EmptyView()
        }
    }
}

enum BeakrSettingsTab: String {
    case device
    case networks
}

private enum NetworkSettingsPane: String {
    case information
    case invitations
}

@MainActor
struct BeakrSettingsView: View {
    @State private var bootstrap: NodeBootstrapModel
    @AppStorage("net.beakr.settings.selectedTab") private var selectedTab = BeakrSettingsTab.networks.rawValue
    @AppStorage(ApplicationLANRuntimeManager.remembersPreviouslyConnectedDevicesKey)
    private var remembersPreviouslyConnectedDevices = true

    init(bootstrap: NodeBootstrapModel) {
        _bootstrap = State(initialValue: bootstrap)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                DeviceDetailsSection(
                    friendlyName: $bootstrap.deviceFriendlyName,
                    nodeID: bootstrap.nodeID,
                    state: bootstrap.state,
                    statusMessage: bootstrap.statusMessage,
                    applyFriendlyName: { Task { await bootstrap.applyDeviceFriendlyName() } }
                )
                Section("Remembered Devices") {
                    Toggle("Remember previously connected devices", isOn: $remembersPreviouslyConnectedDevices)
                    Text("Keeps authenticated device names and last-seen information available while devices are offline. Message history is unaffected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 620, minHeight: 430)
            .accessibilityIdentifier("deviceSettings")
            .tabItem {
                Label("Device", systemImage: "desktopcomputer")
            }
            .tag(BeakrSettingsTab.device.rawValue)

            NetworkManagerWindow(bootstrap: bootstrap)
                .accessibilityIdentifier("networkSettings")
                .tabItem {
                    Label("Networks", systemImage: "network")
                }
                .tag(BeakrSettingsTab.networks.rawValue)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .onChange(of: remembersPreviouslyConnectedDevices, initial: true) { _, enabled in
            Task { await bootstrap.setRemembersPreviouslyConnectedDevices(enabled) }
        }
    }
}

@MainActor
struct NetworkManagerWindow: View {
    @State private var bootstrap: NodeBootstrapModel
    @AppStorage("net.beakr.networkManager.selectedNetworkID") private var persistedNetworkID = ""
    @SceneStorage("net.beakr.networkManager.columnVisibility") private var persistedColumnVisibility = "all"
    @State private var selectedNetworkID: NetworkProfileID?
    @State private var editorMode: NetworkEditorMode = .details
    @State private var editedName = ""
    @State private var displayedInvitationJSON = ""
    @AppStorage("net.beakr.settings.networkPane") private var selectedPane = NetworkSettingsPane.information.rawValue
    @State private var pendingDeletion: OwnedNetworkSummary?
    @State private var pendingDeparture: NetworkSummary?
    @FocusState private var networkListIsFocused: Bool

    init(bootstrap: NodeBootstrapModel) {
        _bootstrap = State(initialValue: bootstrap)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            networkSidebar
        } detail: {
            detailContent
        }
        .accessibilityIdentifier("networkManagerWindow")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 480)
        .confirmationDialog(
            "Delete Network?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { network in
            Button("Delete \(network.displayName)", role: .destructive) {
                pendingDeletion = nil
                Task { await bootstrap.deleteOwnedNetwork(network.id) }
            }
        } message: { network in
            Text("This permanently removes \(network.displayName), its management credentials, and its local data.")
        }
        .confirmationDialog(
            "Forget Network on This Mac?",
            isPresented: Binding(
                get: { pendingDeparture != nil },
                set: { if !$0 { pendingDeparture = nil } }
            ),
            presenting: pendingDeparture
        ) { network in
            Button("Forget \(network.displayName)", role: .destructive) {
                pendingDeparture = nil
                Task { await bootstrap.forgetJoinedNetwork(network.id) }
            }
            Button("Keep Network", role: .cancel) {}
        } message: { network in
            Text(forgetNetworkMessage(
                for: network,
                deviceName: "Mac",
                connectivity: bootstrap.activeNetworkConnectivity
            ))
        }
        .onAppear { restoreSelection() }
        .defaultFocus($networkListIsFocused, true)
        .onChange(of: selectedNetworkID) { _, selection in
            persistedNetworkID = selection?.rawValue.uuidString ?? ""
            editorMode = .details
            editedName = selectedNetwork?.displayName ?? ""
            displayedInvitationJSON = selectedNetwork?.isActive == true ? bootstrap.invitationJSON : ""
        }
        .onChange(of: bootstrap.invitationJSON) { _, invitation in
            displayedInvitationJSON = invitation
        }
        .onChange(of: bootstrap.networks) { _, _ in
            if editorMode != .details,
               let activeNetwork = bootstrap.networks.first(where: \.isActive) {
                selectedNetworkID = activeNetwork.id
            } else {
                restoreSelection()
            }
        }
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { persistedColumnVisibility == "detailOnly" ? .detailOnly : .all },
            set: { persistedColumnVisibility = $0 == .detailOnly ? "detailOnly" : "all" }
        )
    }

    private var networkSidebar: some View {
        List(bootstrap.networks, selection: $selectedNetworkID) { network in
            HStack(spacing: 10) {
                if network.isActive {
                    MacNetworkStatusIcon(
                        connectivity: bootstrap.activeNetworkConnectivity,
                        systemImage: network.canManageNetwork ? "network.badge.shield.half.filled" : "network"
                    )
                } else {
                    Image(systemName: network.canManageNetwork ? "network.badge.shield.half.filled" : "network")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(network.displayName)
                    Text(network.isHostingAuthority ? "Authority hosted on this Mac" : "Authority hosted elsewhere")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if network.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Active")
                }
            }
            .tag(network.id)
        }
        .focused($networkListIsFocused)
        .listStyle(.sidebar)
        .navigationTitle("Networks")
        .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 380)
        .overlay {
            if bootstrap.networks.isEmpty {
                ContentUnavailableView(
                    "No Networks",
                    systemImage: "network.slash",
                    description: Text("Create or join a network to get started.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Menu("Add Network", systemImage: "plus") {
                    Button("Create Network") { editorMode = .create }
                    Button("Join Network") { editorMode = .join }
                }
                .labelStyle(.iconOnly)

                Button("Remove Network", systemImage: "minus", role: .destructive) {
                    requestRemoval()
                }
                .labelStyle(.iconOnly)
                .disabled(selectedNetwork == nil)
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch editorMode {
        case .details:
            if let selectedNetwork {
                networkDetails(selectedNetwork)
            } else {
                ContentUnavailableView(
                    "Select a Network",
                    systemImage: "network",
                    description: Text("Choose a network in the sidebar or add a new one.")
                )
            }
        case .create:
            createNetworkView
        case .join:
            joinNetworkView
        }
    }

    private func networkDetails(_ network: NetworkSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(network.displayName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Menu {
                        if network.isActive {
                            Button("Active Network", systemImage: "checkmark") {}
                                .disabled(true)
                        } else {
                            Button("Switch to This Network", systemImage: "arrow.triangle.swap") {
                                Task { await bootstrap.switchNetwork(to: network.id) }
                            }
                            .disabled(bootstrap.state != .ready)
                        }
                    } label: {
                        Label(
                            network.isActive ? "Active" : "Inactive",
                            systemImage: network.isActive ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            network.isActive
                                ? Color.green.opacity(0.18)
                                : Color.secondary.opacity(0.14)
                        )
                        .clipShape(.capsule)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(
                        network.isActive
                            ? "This network is active"
                            : "Choose an action for this network"
                    )
                }

                Picker("Network Settings", selection: $selectedPane) {
                    Text("Network Information").tag(NetworkSettingsPane.information.rawValue)
                    Text("Invitations").tag(NetworkSettingsPane.invitations.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if selectedPane == NetworkSettingsPane.invitations.rawValue {
                    networkInvitationPane(network)
                } else {
                    networkInformationPane(network)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle(network.displayName)
    }

    private func networkInformationPane(_ network: NetworkSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Network") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Network Name")
                        .font(.caption.weight(.semibold))
                    if network.isHostingAuthority {
                        HStack {
                            TextField("Network Name", text: $editedName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { rename(network) }
                            Button("Save") { rename(network) }
                                .disabled(
                                    editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    editedName.trimmingCharacters(in: .whitespacesAndNewlines) == network.displayName
                                )
                        }
                    } else {
                        Text(network.displayName)
                    }

                    Divider()
                    Text("Network ID")
                        .font(.caption.weight(.semibold))
                    Text(network.networkID.rawValue.uuidString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Divider()
                    Label(
                        network.isHostingAuthority ? "Authority hosted on this Mac" : "Authority hosted elsewhere",
                        systemImage: network.isHostingAuthority ? "desktopcomputer" : "network"
                    )
                    .font(.headline)
                    Text(
                        network.isHostingAuthority
                            ? "This Mac currently hosts authority operations and can manage network trust."
                            : network.canManageNetwork
                                ? "This Mac can manage network trust, while authority hosting is provided elsewhere."
                                : "This Mac participates as a member. Network trust is managed elsewhere."
                    )
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            HStack {
                if !network.isActive {
                    Button("Make Active", systemImage: "checkmark.circle") {
                        Task { await bootstrap.switchNetwork(to: network.id) }
                    }
                }
                Spacer()
                Button(network.isHostingAuthority ? "Delete Network" : "Forget Network…", role: .destructive) {
                    requestRemoval()
                }
            }

            GroupBox("Addressable Devices") {
                NetworkAddressesContent(
                    localName: bootstrap.deviceDisplayName,
                    localID: bootstrap.nodeID,
                    members: network.isActive ? bootstrap.networkMembers : [],
                    onlineMemberIDs: network.isActive ? bootstrap.onlineMemberIDs : [],
                    isLocalDeviceOnline: network.isActive
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func networkInvitationPane(_ network: NetworkSummary) -> some View {
        if network.canManageNetwork {
            GroupBox("Invitation to Join This Network") {
                VStack(alignment: .leading, spacing: 10) {
                    Button(
                        displayedInvitationJSON.isEmpty ? "Generate Invitation" : "Generate New Invitation",
                        systemImage: displayedInvitationJSON.isEmpty ? "qrcode" : "arrow.clockwise"
                    ) {
                        Task { await bootstrap.createInvitation() }
                    }
                    .disabled(!network.isActive || !bootstrap.canCreateInvitations)

                    if !displayedInvitationJSON.isEmpty {
                        InvitationQRCodeView(invitation: displayedInvitationJSON)
                            .frame(width: 320)
                            .frame(minHeight: 390)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Text("Invitation JSON")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $displayedInvitationJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 110, maxHeight: 160)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator)
                        }
                        .accessibilityLabel("Invitation JSON")

                    Text("Create a short-lived invitation that another Beakr device can scan, paste, or import.")
                        .foregroundStyle(.secondary)

                    HStack {
                        InvitationCopyButton(
                            invitation: displayedInvitationJSON,
                            action: copyInvitation
                        )
                        Button("Paste", systemImage: "doc.on.clipboard") { pasteInvitation() }
                        if !displayedInvitationJSON.isEmpty {
                            InvitationShareLink(invitation: displayedInvitationJSON) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        } else {
            ContentUnavailableView(
                "Invitations Managed Elsewhere",
                systemImage: "qrcode",
                description: Text(
                    network.isActive
                        ? "This network is active for messaging, but this Mac is a member. Invitations must be created on the Mac that hosts the network."
                        : "Invitations are created by the Mac that hosts this network."
                )
            )
        }
    }

    private var createNetworkView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Create Network")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Cancel") { editorMode = .details }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Network Name", text: $bootstrap.networkDisplayName)
                        Text("This Mac will store the network management credentials and can create invitations.")
                            .foregroundStyle(.secondary)
                        Button("Create Network", systemImage: "network.badge.shield.half.filled") {
                            Task { await bootstrap.createNetwork() }
                        }
                        .disabled(
                            bootstrap.state == .creatingNetwork ||
                            bootstrap.networkDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        if bootstrap.state == .creatingNetwork {
                            ProgressView("Creating network")
                        }
                    }
                    .padding(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .navigationTitle("Create Network")
    }

    private var joinNetworkView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Join Network")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Cancel") { editorMode = .details }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Invitation JSON", text: $bootstrap.joinInvitationJSON, axis: .vertical)
                            .lineLimit(5...12)
                        Text("Paste the single-use invitation supplied by a network manager.")
                            .foregroundStyle(.secondary)
                        Button("Join Network", systemImage: "person.badge.key") {
                            Task { await bootstrap.joinNetwork() }
                        }
                        .disabled(
                            bootstrap.state == .joiningNetwork ||
                            bootstrap.joinInvitationJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        if bootstrap.state == .joiningNetwork {
                            ProgressView("Joining network")
                        }
                    }
                    .padding(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .navigationTitle("Join Network")
        .networkJoinAlert(
            $bootstrap.networkJoinAlert,
            confirmCollision: { Task { await bootstrap.confirmCollidingNetworkJoin() } },
            confirmReattachment: { Task { await bootstrap.confirmContextReattachment() } }
        )
    }

    private var selectedNetwork: NetworkSummary? {
        if let selectedNetworkID,
           let selected = bootstrap.networks.first(where: { $0.id == selectedNetworkID }) {
            return selected
        }
        return bootstrap.networks.first(where: \.isActive) ?? bootstrap.networks.first
    }

    private var selectedOwnedNetwork: OwnedNetworkSummary? {
        guard let selectedNetwork else { return nil }
        return bootstrap.ownedNetworks.first { $0.id == selectedNetwork.id }
    }

    private func restoreSelection() {
        if let persistedUUID = UUID(uuidString: persistedNetworkID) {
            let persistedID = NetworkProfileID(rawValue: persistedUUID)
            if bootstrap.networks.contains(where: { $0.id == persistedID }) {
                selectedNetworkID = persistedID
                editedName = selectedNetwork?.displayName ?? ""
                return
            }
        }
        let initial = bootstrap.networks.first(where: \.isActive) ?? bootstrap.networks.first
        selectedNetworkID = initial?.id
        editedName = initial?.displayName ?? ""
        displayedInvitationJSON = initial?.isActive == true ? bootstrap.invitationJSON : ""
    }

    private func rename(_ network: NetworkSummary) {
        guard network.canManageNetwork else { return }
        Task { await bootstrap.renameOwnedNetwork(network.id, to: editedName) }
    }

    private func requestRemoval() {
        guard let selectedNetwork else { return }
        if let selectedOwnedNetwork {
            pendingDeletion = selectedOwnedNetwork
        } else {
            pendingDeparture = selectedNetwork
        }
    }

    private func copyInvitation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedInvitationJSON, forType: .string)
    }

    private func pasteInvitation() {
        guard let invitation = NSPasteboard.general.string(forType: .string) else { return }
        displayedInvitationJSON = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum NetworkEditorMode {
    case details
    case create
    case join

    var title: LocalizedStringKey {
        switch self {
        case .details: "Network Details"
        case .create: "Create Network"
        case .join: "Join Network"
        }
    }
}

#endif

private struct MailboxSelection: Hashable {
    let networkID: NetworkProfileID?
    let contextID: ContextID?
    let mailbox: Mailbox

    init(networkID: NetworkProfileID, mailbox: Mailbox) {
        self.networkID = networkID
        contextID = nil
        self.mailbox = mailbox
    }

    init(contextID: ContextID, mailbox: Mailbox) {
        networkID = nil
        self.contextID = contextID
        self.mailbox = mailbox
    }
}

#if os(macOS)
private enum MacMemberAvailability: Hashable {
    case online
    case offline

    var title: LocalizedStringKey {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        }
    }
}

private enum MacSidebarRoute: Hashable {
    case mailbox(MailboxSelection)
    case members(NetworkProfileID, MacMemberAvailability)

    var mailboxSelection: MailboxSelection? {
        guard case .mailbox(let selection) = self else { return nil }
        return selection
    }
}

private enum MacDetailRoute: Hashable {
    case message(MailMessageSelection)
    case device(NetworkProfileID, UUID)

    var messageSelection: MailMessageSelection? {
        guard case .message(let selection) = self else { return nil }
        return selection
    }
}
#endif

private struct ArchivedContextRow: View {
    let mailbox: Mailbox

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mailbox == .inbox ? "tray" : "paperplane")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mailbox == .inbox ? "Inbox" : "Outbox")
                Text("Preserved mailbox — read only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(macOS)
private struct MacMemberDetail: Identifiable, Equatable {
    let networkID: NetworkProfileID
    let networkName: String
    let deviceID: UUID
    let displayName: String
    let isLocalDevice: Bool
    let isOnline: Bool
    let isActiveNetwork: Bool
    let lastSeen: Date?

    var id: UUID { deviceID }
}

private struct MacMemberDirectorySnapshot {
    let networks: [NetworkSummary]
    let localDeviceName: String
    let localDeviceID: UUID?
    let activeNetworkMembers: [NetworkMemberSummary]
    let onlineMemberIDs: Set<UUID>

    func members(
        networkID: NetworkProfileID,
        availability: MacMemberAvailability
    ) -> [MacMemberDetail] {
        allMembers(networkID: networkID)
            .filter { availability == .online ? $0.isOnline : !$0.isOnline }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func member(networkID: NetworkProfileID, deviceID: UUID) -> MacMemberDetail? {
        allMembers(networkID: networkID).first { $0.deviceID == deviceID }
    }

    private func allMembers(networkID: NetworkProfileID) -> [MacMemberDetail] {
        guard let network = networks.first(where: { $0.id == networkID }) else { return [] }
        var result: [MacMemberDetail] = []
        if let localDeviceID {
            result.append(MacMemberDetail(
                networkID: network.id,
                networkName: network.displayName,
                deviceID: localDeviceID,
                displayName: localDeviceName,
                isLocalDevice: true,
                isOnline: network.isActive,
                isActiveNetwork: network.isActive,
                lastSeen: nil
            ))
        }
        guard network.isActive else { return result }
        result.append(contentsOf: activeNetworkMembers.map { member in
            MacMemberDetail(
                networkID: network.id,
                networkName: network.displayName,
                deviceID: member.id,
                displayName: member.displayName,
                isLocalDevice: false,
                isOnline: onlineMemberIDs.contains(member.id),
                isActiveNetwork: true,
                lastSeen: member.lastSeen
            )
        })
        return result
    }
}

private struct MacDeviceProperties: View {
    let member: MacMemberDetail

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: member.displayName)

                LabeledContent("Device ID") {
                    Text(member.deviceID.uuidString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                LabeledContent("Role", value: member.isLocalDevice ? "This Device" : "Network Peer")

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(member.isOnline ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(member.isOnline ? "Online" : "Offline")
                            .foregroundStyle(member.isOnline ? Color.green : Color.secondary)
                    }
                }

                if !member.isOnline, let lastSeen = member.lastSeen {
                    LabeledContent("Last Seen") {
                        Text(lastSeen, format: .relative(presentation: .named))
                    }
                }
            }

            Section("Network Membership") {
                LabeledContent("Beakr'Net", value: member.networkName)
                    .foregroundStyle(member.isActiveNetwork ? Color.green : Color.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(member.displayName)
    }
}

private struct MacNetworkOverviewSection: View {
    let network: NetworkSummary
    let incomingCount: Int
    let outgoingCount: Int
    let onlineMemberCount: Int
    let offlineMemberCount: Int
    let activeConnectivity: ActiveNetworkConnectivity
    let membersAreAvailable: Bool

    @State private var networkIsExpanded = false
    @State private var mailboxesAreExpanded = false
    @State private var membersAreExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $networkIsExpanded) {
                DisclosureGroup(isExpanded: $mailboxesAreExpanded) {
                    Label("Inbox", systemImage: "tray")
                        .badge(incomingCount)
                        .tag(MacSidebarRoute.mailbox(
                            MailboxSelection(networkID: network.id, mailbox: .inbox)
                        ))

                    Label("Outbox", systemImage: "paperplane")
                        .badge(outgoingCount)
                        .tag(MacSidebarRoute.mailbox(
                            MailboxSelection(networkID: network.id, mailbox: .outbox)
                        ))
                } label: {
                    Label("Mailboxes", systemImage: "tray.2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            mailboxesAreExpanded.toggle()
                        }
                }

                DisclosureGroup(isExpanded: $membersAreExpanded) {
                    MacSidebarStatusLabel("Online", systemImage: "circle.fill")
                        .foregroundStyle(membersAreAvailable ? Color.primary : Color.secondary)
                        .badge(onlineMemberCount)
                        .tag(MacSidebarRoute.members(network.id, .online))

                    MacSidebarStatusLabel("Offline", systemImage: "circle")
                        .foregroundStyle(.secondary)
                        .badge(offlineMemberCount)
                        .tag(MacSidebarRoute.members(network.id, .offline))
                } label: {
                    Label("Members", systemImage: "shareplay")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            membersAreExpanded.toggle()
                        }
                }
            } label: {
                MacNetworkHeaderLabel(
                    network: network,
                    activeConnectivity: activeConnectivity
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    networkIsExpanded.toggle()
                }
            }
        .task(id: network.isActive) {
            networkIsExpanded = network.isActive
            mailboxesAreExpanded = false
            membersAreExpanded = false
        }
    }
}

private struct MacSidebarStatusLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.small)
        }
    }
}

private struct MacNetworkHeaderLabel: View {
    let network: NetworkSummary
    let activeConnectivity: ActiveNetworkConnectivity

    private var foregroundStyle: AnyShapeStyle {
        guard network.isActive else { return AnyShapeStyle(.secondary) }
        return activeConnectivity.networkForegroundStyle
    }

    var body: some View {
        Label {
            Text(network.displayName)
                .fontWeight(.semibold)
                .foregroundStyle(foregroundStyle)
        } icon: {
            Image(systemName: network.canManageNetwork
                ? "network.badge.shield.half.filled"
                : "network")
                .foregroundStyle(foregroundStyle)
        }
    }
}
#endif

private enum Mailbox: Hashable {
    case inbox
    case outbox

    var title: LocalizedStringKey { self == .inbox ? "Inbox" : "Outbox" }
}

private func forgetNetworkMessage(
    for network: NetworkSummary,
    deviceName: String,
    connectivity: ActiveNetworkConnectivity
) -> String {
    let consequence = "Forgetting \(network.displayName) removes its local identity, credentials, and connection from this \(deviceName). Existing messages are preserved. You will need a new invitation from the network authority to join again. The network and its authority are not deleted."
    guard network.isActive, connectivity == .inactive else { return consequence }
    return "This network may simply be out of range. Forgetting it will not restore connectivity. \(consequence)"
}

private enum InboxFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case flagged = "Flagged"

    var id: Self { self }
}

private enum MailMessageSelection: Hashable {
    case incoming(UUID)
    case outgoing(UUID)
}

private extension ActiveNetworkConnectivity {
    var networkTintColor: Color {
        switch self {
        case .inactive:
            return .secondary
        case .reconnecting:
            return .orange
        case .discoveringPeers, .readyNoPeers:
            return .accentColor
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    var networkForegroundStyle: AnyShapeStyle {
        AnyShapeStyle(networkTintColor)
    }

    var isTransitioning: Bool {
        self == .reconnecting || self == .discoveringPeers
    }

    var statusColor: Color {
        switch self {
        case .inactive:
            return .secondary
        case .reconnecting:
            return .orange
        case .discoveringPeers:
            return .blue
        case .readyNoPeers:
            return .blue
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    var compactStatusTitle: String {
        switch self {
        case .inactive:
            return "Offline"
        case .reconnecting:
            return "Connecting"
        case .discoveringPeers:
            return "Finding devices"
        case .readyNoPeers:
            return "No other devices online"
        case .connected(let peerCount):
            return peerCount == 1 ? "1 other device online" : "\(peerCount) other devices online"
        case .failed:
            return "Connection failed"
        }
    }

    var localDeviceStatus: String {
        switch self {
        case .inactive:
            return "Offline"
        case .reconnecting:
            return "Connecting"
        case .discoveringPeers:
            return "Authenticating"
        case .readyNoPeers, .connected:
            return "Online"
        case .failed:
            return "Unavailable"
        }
    }

    var connectionDescription: String {
        switch self {
        case .inactive:
            return "Stopped"
        case .reconnecting:
            return "Starting"
        case .discoveringPeers:
            return "Discovering and authenticating"
        case .readyNoPeers, .connected:
            return "Authenticated"
        case .failed:
            return "Error"
        }
    }
}

private struct MacNetworkStatusIcon: View {
    let connectivity: ActiveNetworkConnectivity
    var systemImage = "network"

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(connectivity.networkForegroundStyle)
            .symbolEffect(
                .pulse.wholeSymbol,
                options: .repeating.speed(0.7),
                isActive: connectivity.isTransitioning
            )
    }
}

private struct MailboxSummaryHeader: View {
    let networkName: String
    let networkConnectivity: ActiveNetworkConnectivity
    let mailbox: Mailbox
    let unreadCount: Int
    let queuedCount: Int
    let messageCount: Int
    let lastUpdated: Date?

    var body: some View {
        mailboxMetadata
            .font(.caption)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mailboxMetadata: some View {
        HStack(spacing: 5) {
            Text(networkName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(networkConnectivity.statusColor)
                .textCase(nil)
            Text("·")
                .foregroundStyle(.secondary)
            mailboxStatus
        }
    }

    private var connectivityLabel: some View {
        Text(verbatim: connectivityStatusText)
            .foregroundStyle(networkConnectivity.statusColor)
    }

    @ViewBuilder
    private var mailboxStatus: some View {
        if mailbox == .inbox, unreadCount > 0 {
            Text("\(unreadCount) Unread")
                .foregroundStyle(.secondary)
        } else if mailbox == .outbox, queuedCount > 0 {
            Text("\(queuedCount) Queued")
                .foregroundStyle(.secondary)
        } else if let lastUpdated {
            Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                .foregroundStyle(.secondary)
        } else {
            Text("\(messageCount) Messages")
                .foregroundStyle(.secondary)
        }
    }

    private var connectivityStatusText: String {
        switch networkConnectivity {
        case .inactive:
            "Network inactive. Pull down to connect."
        case .reconnecting:
            "Reconnecting to network…"
        case .discoveringPeers:
            "Discovering nearby devices…"
        case .readyNoPeers:
            "Ready — no other devices online."
        case .connected(let peerCount):
            if peerCount == 1 {
                "Connected to 1 device."
            } else {
                "Connected to \(peerCount) devices."
            }
        case .failed:
            "Unable to connect. Pull down to retry."
        }
    }
}

private struct IncomingMailRow: View {
    let sender: String
    let subject: String
    let preview: String
    let receivedAt: Date
    let isRead: Bool
    let isFlagged: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isRead ? Color.clear : Color.blue)
                .frame(width: 9, height: 9)
                .overlay { Circle().stroke(isRead ? Color.clear : Color.blue, lineWidth: 1) }
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text(sender)
                        .font(.headline)
                        .fontWeight(isRead ? .regular : .semibold)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1, reservesSpace: true)
                    Spacer()
                    Text(receivedDateText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(subject)
                        .fontWeight(isRead ? .regular : .semibold)
                        .lineLimit(1, reservesSpace: true)
                    Spacer(minLength: 8)
                    if isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.primary)
                            .accessibilityLabel("Flagged")
                    }
                }
                Text(preview)
                    .lineLimit(1, reservesSpace: true)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var receivedDateText: String {
        if Calendar.current.isDateInToday(receivedAt) {
            return receivedAt.formatted(date: .omitted, time: .shortened)
        }
        return receivedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct OutgoingMailRow: View {
    let recipient: String
    let messageBody: String
    let state: MessageDeliveryState
    let deliveredAt: Date?
    let openedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MessageReceiptIndicator(state: state, isOpened: openedAt != nil)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text(recipient)
                        .font(.headline)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let openedAt {
                        Text("Opened \(openedAt, format: .dateTime.month(.abbreviated).day().hour().minute())")
                    } else if let deliveredAt {
                        Text("Delivered \(deliveredAt, format: .dateTime.month(.abbreviated).day().hour().minute())")
                    } else {
                        Text(state.title)
                    }
                }
                .font(.subheadline)

                Text(messageBody)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)

                if let deliveredAt, openedAt != nil {
                    Text("Delivered \(deliveredAt, format: .dateTime.month(.abbreviated).day().hour().minute())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MessageReceiptIndicator: View {
    let state: MessageDeliveryState
    let isOpened: Bool

    var body: some View {
        HStack(spacing: -4) {
            Circle()
                .fill(state.color)
                .frame(width: 11, height: 11)
            Circle()
                .fill(isOpened ? Color.green : Color.clear)
                .overlay {
                    Circle().stroke(isOpened ? Color.green : Color.secondary, lineWidth: 1.5)
                }
                .frame(width: 11, height: 11)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: isOpened ? "\(state.title), opened" : "\(state.title), not opened"))
    }
}

private struct MailMessageDetail: View {
    let heading: String
    let address: String?
    let metadata: String
    let messageBody: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(heading)
                    .font(.title2.weight(.semibold))

                if let address {
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Text(messageBody)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
    }
}

private struct NetworkJoinAlertModifier: ViewModifier {
    @Binding var result: NetworkJoinAlert?
    let confirmCollision: () -> Void
    let confirmReattachment: () -> Void

    func body(content: Content) -> some View {
        content.alert(item: $result) { result in
            if result.reattachmentContextID != nil {
                Alert(
                    title: Text(result.title),
                    message: Text(result.message),
                    primaryButton: .default(Text("Reconnect Preserved Context"), action: confirmReattachment),
                    secondaryButton: .cancel(Text("Keep Context Archived"))
                )
            } else if let suggestedName = result.suggestedName {
                Alert(
                    title: Text(result.title),
                    message: Text("\(result.message)\n\nJoin locally as \(suggestedName)?"),
                    primaryButton: .default(Text("Join as \(suggestedName)"), action: confirmCollision),
                    secondaryButton: .cancel()
                )
            } else {
                Alert(
                    title: Text(result.title),
                    message: Text(result.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
}

private extension View {
    func networkJoinAlert(
        _ result: Binding<NetworkJoinAlert?>,
        confirmCollision: @escaping () -> Void,
        confirmReattachment: @escaping () -> Void
    ) -> some View {
        modifier(NetworkJoinAlertModifier(
            result: result,
            confirmCollision: confirmCollision,
            confirmReattachment: confirmReattachment
        ))
    }
}

#if os(iOS)
private struct IOSMailRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: MessageComposerModel
    let bootstrap: NodeBootstrapModel

    @State private var showingComposer = false
    @State private var showingManagement = false
    @State private var confirmingHistoryDeletion = false
    @State private var confirmingQueuedDeletion = false
    @State private var isCommunicationIndicatorActive = false
    @State private var appleNetworkSnapshot = AppleNetworkSnapshot.unknown

    var body: some View {
        NavigationStack {
            IOSMailboxListView(
                networks: bootstrap.networks,
                archivedContexts: bootstrap.archivedContexts,
                incomingCount: model.unreadIncomingCount,
                outgoingCount: model.outgoingMessages.count,
                localDeviceName: bootstrap.deviceDisplayName,
                localDeviceID: bootstrap.nodeID,
                networkMembers: bootstrap.networkMembers,
                onlineMemberIDs: bootstrap.onlineMemberIDs,
                networkConnectivity: bootstrap.activeNetworkConnectivity,
                appleNetworkSnapshot: appleNetworkSnapshot,
                bootstrapState: bootstrap.state,
                refresh: refreshNetwork,
                deleteArchivedContext: bootstrap.deleteArchivedContext
            )
            .navigationDestination(for: IOSMemberDetailRoute.self) { member in
                IOSMemberDetailView(member: member, bootstrap: bootstrap)
            }
            .navigationDestination(for: MailboxSelection.self) { selection in
                if let contextID = selection.contextID,
                   let context = bootstrap.archivedContexts.first(where: { $0.id == contextID }) {
                    ArchivedContextMailboxView(
                        contextID: context.id,
                        contextName: context.displayName,
                        mailbox: selection.mailbox,
                        incomingMessages: bootstrap.archivedIncomingMessages[contextID] ?? [],
                        mailboxMetadata: bootstrap.archivedMailboxMetadata[contextID] ?? .empty,
                        deleteContext: bootstrap.deleteArchivedContext
                    )
                } else if let networkID = selection.networkID {
                    IOSMailboxMessageListView(
                        selection: selection,
                        networkName: bootstrap.networks.first(where: { $0.id == networkID })?.displayName ?? "Network",
                        networkConnectivity: bootstrap.networks.contains(where: { $0.id == networkID && $0.isActive })
                            ? bootstrap.activeNetworkConnectivity
                            : .inactive,
                        appleNetworkSnapshot: appleNetworkSnapshot,
                        model: model,
                        switchNetwork: switchNetwork,
                        refresh: refreshNetwork
                    )
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        IOSNetworkSwitcherMenu(
                            networks: bootstrap.networks,
                            connectivity: bootstrap.activeNetworkConnectivity,
                            statusTitle: bootstrap.activeNetworkStatusTitle,
                            switchNetwork: switchNetwork,
                            manageNetworks: { showingManagement = true }
                        )

                        Image(systemName: "waveform")
                            .foregroundStyle(isCommunicationIndicatorActive ? Color.accentColor : Color.secondary)
                            .symbolEffect(
                                .pulse,
                                options: .repeating,
                                isActive: isCommunicationIndicatorActive
                            )
                            .accessibilityLabel("Message activity")
                            .accessibilityValue(isCommunicationIndicatorActive ? "Active" : "Idle")
                    }
                    .accessibilityElement(children: .contain)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Compose", systemImage: "square.and.pencil") {
                        showingComposer = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            IOSMessageComposerView(model: model, dismiss: { showingComposer = false })
        }
        .sheet(isPresented: $showingManagement) {
            IOSBeakrManagementView(
                model: model,
                bootstrap: bootstrap,
                dismiss: { showingManagement = false }
            )
        }
        .task(id: model.communicationActivitySequence) {
            guard model.communicationActivitySequence > 0 else { return }
            isCommunicationIndicatorActive = true
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            isCommunicationIndicatorActive = false
        }
        .task {
            appleNetworkSnapshot = await AppleNetworkSnapshot.capture()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { appleNetworkSnapshot = await AppleNetworkSnapshot.capture() }
        }
        .confirmationDialog("Delete Message History?", isPresented: $confirmingHistoryDeletion) {
            Button("Delete Message History", role: .destructive) {
                Task { await model.deleteMessageHistory() }
            }
        } message: {
            Text("Received, delivered, and failed messages will be deleted. Queued messages will be preserved.")
        }
        .confirmationDialog("Delete Queued Messages?", isPresented: $confirmingQueuedDeletion) {
            Button("Delete Queued Messages", role: .destructive) {
                Task { await model.deleteQueuedMessages() }
            }
        } message: {
            Text("Queued sends will be cancelled and removed. Delivered message history will be preserved.")
        }
        .networkJoinAlert(
            Binding(
                get: { bootstrap.networkJoinAlert },
                set: { bootstrap.networkJoinAlert = $0 }
            ),
            confirmCollision: { Task { await bootstrap.confirmCollidingNetworkJoin() } },
            confirmReattachment: { Task { await bootstrap.confirmContextReattachment() } }
        )
    }

    private func switchNetwork(_ networkID: NetworkProfileID) {
        guard !bootstrap.networks.contains(where: { $0.id == networkID && $0.isActive }) else { return }
        Task { await bootstrap.switchNetwork(to: networkID) }
    }

    private func refreshNetwork() async {
        await bootstrap.reconnectActiveNetwork()
        guard !Task.isCancelled else { return }
        appleNetworkSnapshot = await AppleNetworkSnapshot.capture()
    }
}

private struct IOSNetworkSwitcherMenu: View {
    let networks: [NetworkSummary]
    let connectivity: ActiveNetworkConnectivity
    let statusTitle: String
    let switchNetwork: (NetworkProfileID) -> Void
    let manageNetworks: () -> Void

    var body: some View {
        Menu {
            ForEach(networks) { network in
                Button {
                    switchNetwork(network.id)
                } label: {
                    Label(
                        network.displayName,
                        systemImage: network.isActive ? "checkmark.circle.fill" : "circle"
                    )
                }
                .disabled(network.isActive)
            }

            if !networks.isEmpty {
                Divider()
            }

            Button("Manage Networks…", systemImage: "gearshape", action: manageNetworks)
        } label: {
            NetworkStatusIcon(connectivity: connectivity)
        }
        .accessibilityLabel("Switch Network")
        .accessibilityValue(statusTitle)
    }
}

private struct NetworkStatusIcon: View {
    let connectivity: ActiveNetworkConnectivity

    @ViewBuilder
    var body: some View {
        if connectivity.isTransitioning {
            Image(systemName: "network")
                .foregroundStyle(connectivity == .reconnecting ? Color.secondary : connectivity.statusColor)
                .symbolEffect(.pulse, options: .repeating.speed(0.7), isActive: true)
        } else {
            Image(systemName: "network")
                .foregroundStyle(connectivity.statusColor)
        }
    }
}

private struct IOSMailboxListView: View {
    @Environment(\.scenePhase) private var scenePhase
    let networks: [NetworkSummary]
    let archivedContexts: [ContextSummary]
    let incomingCount: Int
    let outgoingCount: Int
    let localDeviceName: String
    let localDeviceID: UUID?
    let networkMembers: [NetworkMemberSummary]
    let onlineMemberIDs: Set<UUID>
    let networkConnectivity: ActiveNetworkConnectivity
    let appleNetworkSnapshot: AppleNetworkSnapshot
    let bootstrapState: NodeBootstrapState
    let refresh: () async -> Void
    let deleteArchivedContext: (ContextID) async -> Void
    @State private var refreshPhase = NetworkRefreshPhase.idle
    @State private var hasCompletedManualRefresh = false
    @State private var refreshResultDismissTask: Task<Void, Never>?
    @State private var pullStage = NetworkPullStage.hidden
    @State private var armedHapticSequence = 0
    @State private var prioritizedNetworkID: NetworkProfileID?
    @State private var expandedNetworkIDs: Set<NetworkProfileID> = []
    @State private var expandedMailboxIDs: Set<NetworkProfileID> = []
    @State private var expandedMemberIDs: Set<NetworkProfileID> = []
    @State private var previousActiveNetworkID: NetworkProfileID?
    @State private var hasInitializedExpansion = false
    @State private var contextPendingDeletion: ContextSummary?

    private var orderedNetworks: [NetworkSummary] {
        guard let prioritizedNetworkID = prioritizedNetworkID
            ?? networks.first(where: \.isActive)?.id,
              let prioritizedIndex = networks.firstIndex(where: { $0.id == prioritizedNetworkID }) else {
            return networks
        }

        var orderedNetworks = networks
        let prioritizedNetwork = orderedNetworks.remove(at: prioritizedIndex)
        orderedNetworks.insert(prioritizedNetwork, at: 0)
        return orderedNetworks
    }

    private var refreshStatus: LocalizedStringResource? {
        if refreshPhase == .refreshing {
            return "Refreshing Networks…"
        }

        if refreshPhase == .finished {
            return onlineMemberIDs.isEmpty ? "No Peers Discovered" : nil
        }

        return switch pullStage {
        case .hidden:
            nil
        case .peek:
            "Pull to Refresh"
        case .armed:
            "Release to Refresh"
        }
    }

    var body: some View {
        List {
            MailboxPageTitleRow(
                title: "Beakr'Net",
                subtitle: "Networks",
                status: refreshStatus,
                statusDate: hasCompletedManualRefresh ? appleNetworkSnapshot.checkedAt : nil
            )
            .padding(.top, -10)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))

            ForEach(orderedNetworks) { network in
                IOSNetworkOverviewSection(
                    network: network,
                    incomingCount: network.isActive ? incomingCount : 0,
                    outgoingCount: network.isActive ? outgoingCount : 0,
                    localDeviceName: localDeviceName,
                    localDeviceID: localDeviceID,
                    members: network.isActive ? networkMembers : [],
                    onlineMemberIDs: network.isActive ? onlineMemberIDs : [],
                    connectivity: networkConnectivity,
                    networkIsExpanded: Binding(
                        get: { expandedNetworkIDs.contains(network.id) },
                        set: { isExpanded in
                            if isExpanded {
                                expandedNetworkIDs.insert(network.id)
                            } else {
                                expandedNetworkIDs.remove(network.id)
                            }
                        }
                    ),
                    mailboxesAreExpanded: Binding(
                        get: { expandedMailboxIDs.contains(network.id) },
                        set: { isExpanded in
                            if isExpanded {
                                expandedMailboxIDs.insert(network.id)
                            } else {
                                expandedMailboxIDs.remove(network.id)
                            }
                        }
                    ),
                    membersAreExpanded: Binding(
                        get: { expandedMemberIDs.contains(network.id) },
                        set: { isExpanded in
                            if isExpanded {
                                expandedMemberIDs.insert(network.id)
                            } else {
                                expandedMemberIDs.remove(network.id)
                            }
                        }
                    )
                )
            }

            if !archivedContexts.isEmpty {
                Section("Preserved Contexts") {
                    ForEach(archivedContexts) { context in
                        DisclosureGroup {
                            NavigationLink(value: MailboxSelection(contextID: context.id, mailbox: .inbox)) {
                                ArchivedContextRow(mailbox: .inbox)
                            }

                            NavigationLink(value: MailboxSelection(contextID: context.id, mailbox: .outbox)) {
                                ArchivedContextRow(mailbox: .outbox)
                            }
                        } label: {
                            Label(context.displayName, systemImage: "archivebox")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                contextPendingDeletion = context
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await performNetworkRefresh() }
        .alert(
            "Delete Preserved Context?",
            isPresented: Binding(
                get: { contextPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        contextPendingDeletion = nil
                    }
                }
            ),
            presenting: contextPendingDeletion
        ) { context in
            Button("Cancel", role: .cancel) {
                contextPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                contextPendingDeletion = nil
                Task {
                    await deleteArchivedContext(context.id)
                }
            }
        } message: { context in
            Text("Delete “\(context.displayName)” and its preserved Inbox, Outbox, and all local data? This cannot be undone.")
        }
        .onChange(of: networks, initial: true) { _, networks in
            guard prioritizedNetworkID == nil
                    || !networks.contains(where: { $0.id == prioritizedNetworkID }) else {
                return
            }
            prioritizedNetworkID = networks.first(where: \.isActive)?.id
        }
        .onChange(of: networks, initial: true) { _, networks in
            let activeNetworkID = networks.first(where: \.isActive)?.id
            let availableNetworkIDs = Set(networks.map(\.id))

            expandedNetworkIDs.formIntersection(availableNetworkIDs)
            expandedMailboxIDs.formIntersection(availableNetworkIDs)
            expandedMemberIDs.formIntersection(availableNetworkIDs)

            guard !hasInitializedExpansion || activeNetworkID != previousActiveNetworkID else {
                return
            }

            expandedNetworkIDs = activeNetworkID.map { [$0] } ?? []
            expandedMailboxIDs.removeAll()
            expandedMemberIDs.removeAll()
            previousActiveNetworkID = activeNetworkID
            hasInitializedExpansion = true
        }
        .networkPullTracking(
            isRefreshing: refreshPhase == .refreshing,
            pullStage: $pullStage,
            armedHapticSequence: $armedHapticSequence
        )
        .sensoryFeedback(.impact(weight: .light), trigger: armedHapticSequence)
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelNetworkRefreshPresentation()
        }
        .overlay {
            if networks.isEmpty && archivedContexts.isEmpty {
                if bootstrapState == .starting {
                    ProgressView("Loading Networks…")
                } else {
                    ContentUnavailableView(
                        "No Network",
                        systemImage: "network.slash",
                        description: Text("Use the Network button to join a Beakr network.")
                    )
                }
            }
        }
    }

    private func performNetworkRefresh() async {
        guard refreshPhase != .refreshing else { return }
        refreshResultDismissTask?.cancel()
        pullStage = .hidden
        refreshPhase = .refreshing
        await refresh()
        guard !Task.isCancelled else { return }
        hasCompletedManualRefresh = true
        withAnimation {
            prioritizedNetworkID = networks.first(where: \.isActive)?.id
        }
        refreshPhase = .finished
        refreshResultDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            refreshPhase = .idle
        }
    }

    private func cancelNetworkRefreshPresentation() {
        refreshResultDismissTask?.cancel()
        refreshResultDismissTask = nil
        refreshPhase = .idle
    }
}

private struct IOSMemberDetailRoute: Hashable {
    let networkName: String
    let deviceID: UUID?
    let displayName: String
    let isLocalDevice: Bool
    let isOnline: Bool
    let isActiveNetwork: Bool
}

private struct IOSMemberDetailView: View {
    let member: IOSMemberDetailRoute
    let bootstrap: NodeBootstrapModel

    @State private var displayName: String
    @State private var nameDraft: String
    @State private var isEditingName = false

    init(member: IOSMemberDetailRoute, bootstrap: NodeBootstrapModel) {
        self.member = member
        self.bootstrap = bootstrap
        _displayName = State(initialValue: member.displayName)
        _nameDraft = State(initialValue: member.displayName)
    }

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: displayName)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        guard member.isLocalDevice else { return }
                        nameDraft = displayName
                        isEditingName = true
                    }

                LabeledContent("Device ID") {
                    if let deviceID = member.deviceID {
                        Text(deviceID.uuidString)
                            .font(.caption.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text("Not Available")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Role", value: "Network Peer")

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(member.isOnline ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)

                        Text(member.isOnline ? "Online" : "Offline")
                            .foregroundStyle(member.isOnline ? Color.green : Color.secondary)
                    }
                }
                .padding(.vertical, -4)
            }
            .listSectionSpacing(20)

            Section("Network Membership") {
                HStack(alignment: .top) {
                    Text("Beakr'Net")

                    Spacer(minLength: 16)

                    Text(member.networkName)
                        .foregroundStyle(member.isActiveNetwork ? Color.green : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Edit Device Name", isPresented: $isEditingName) {
            TextField("Device Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveDeviceName()
            }
            .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter the name this device advertises to network members.")
        }
    }

    private func saveDeviceName() {
        let normalizedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard member.isLocalDevice, !normalizedName.isEmpty else { return }
        displayName = normalizedName
        bootstrap.deviceFriendlyName = normalizedName
        Task {
            await bootstrap.applyDeviceFriendlyName()
        }
    }
}

private struct IOSNetworkOverviewSection: View {
    let network: NetworkSummary
    let incomingCount: Int
    let outgoingCount: Int
    let localDeviceName: String
    let localDeviceID: UUID?
    let members: [NetworkMemberSummary]
    let onlineMemberIDs: Set<UUID>
    let connectivity: ActiveNetworkConnectivity
    @Binding var networkIsExpanded: Bool
    @Binding var mailboxesAreExpanded: Bool
    @Binding var membersAreExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $networkIsExpanded) {
                DisclosureGroup(isExpanded: $mailboxesAreExpanded) {
                    NavigationLink(value: MailboxSelection(networkID: network.id, mailbox: .inbox)) {
                        HStack {
                            Image(systemName: "tray.and.arrow.down")
                            Text("Inbox")
                        }
                        .padding(.vertical, -7)
                        .badge(incomingCount)
                    }

                    NavigationLink(value: MailboxSelection(networkID: network.id, mailbox: .outbox)) {
                        HStack {
                            Image(systemName: "tray.and.arrow.up")
                            Text("Outbox")
                        }
                        .padding(.vertical, -7)
                        .badge(outgoingCount)
                    }
                } label: {
                    Label("Mailboxes", systemImage: "tray")
                }

                DisclosureGroup(isExpanded: $membersAreExpanded) {
                NavigationLink(value: IOSMemberDetailRoute(
                    networkName: network.displayName,
                    deviceID: localDeviceID,
                    displayName: localDeviceName,
                    isLocalDevice: true,
                    isOnline: network.isActive,
                    isActiveNetwork: network.isActive
                )) {
                    IOSNetworkMemberRow(
                        displayName: localDeviceName,
                        detail: "This Device",
                        isOnline: network.isActive
                    )
                }

                ForEach(members) { member in
                    NavigationLink(value: IOSMemberDetailRoute(
                        networkName: network.displayName,
                        deviceID: member.id,
                        displayName: member.displayName,
                        isLocalDevice: false,
                        isOnline: onlineMemberIDs.contains(member.id),
                        isActiveNetwork: network.isActive
                    )) {
                        IOSNetworkMemberRow(
                            displayName: member.displayName,
                            detail: nil,
                            isOnline: onlineMemberIDs.contains(member.id)
                        )
                    }
                }

                if !network.isActive {
                    Text("Make this network active to update its members.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if members.isEmpty {
                    Text("No other members have been discovered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                } label: {
                    Label("Members", systemImage: "shareplay")
                }
            } label: {
                NetworkMailboxHeader(
                    name: network.displayName,
                    isActive: network.isActive,
                    connectivity: connectivity,
                    topSpacingAdjustment: 0
                )
            }
        }
        .listSectionSpacing(22)
    }
}

private struct IOSNetworkMemberRow: View {
    let displayName: String
    let detail: LocalizedStringResource?
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, -7)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOnline ? "Online" : "Offline")
    }
}

private struct ArchivedContextMailboxView: View {
    @Environment(\.dismiss) private var dismiss
    let contextID: ContextID
    let contextName: String
    let mailbox: Mailbox
    let incomingMessages: [IncomingMessage]
    let mailboxMetadata: ContextMailboxMetadata
    let deleteContext: (ContextID) async -> Void
    @State private var confirmingDeletion = false

    var body: some View {
        List {
            Section {
                Label("Preserved Context — Read Only", systemImage: "archivebox")
                    .foregroundStyle(.secondary)
                LabeledContent("Context", value: contextName)
            } footer: {
                Text("Reconnect this Context with a new invitation to send, reply, or change its stored messages.")
            }

            switch mailbox {
            case .inbox:
                ForEach(incomingMessages) { message in
                    NavigationLink {
                        MailMessageDetail(
                            heading: message.source.map { displayName(for: $0) } ?? "Unknown Sender",
                            address: message.source?.uuidString,
                            metadata: message.receivedAt.formatted(date: .abbreviated, time: .shortened),
                            messageBody: message.body
                        )
                    } label: {
                        IncomingMailRow(
                            sender: message.source.map { displayName(for: $0) } ?? "Unknown Sender",
                            subject: message.subject,
                            preview: message.preview,
                            receivedAt: message.receivedAt,
                            isRead: mailboxMetadata.readMessageIDs.contains(message.id),
                            isFlagged: mailboxMetadata.flaggedMessageIDs.contains(message.id)
                        )
                    }
                }
            case .outbox:
                ForEach(mailboxMetadata.outgoingMessages) { message in
                    NavigationLink {
                        MailMessageDetail(
                            heading: displayName(for: message.destination),
                            address: message.destination.uuidString,
                            metadata: message.state.detailTitle,
                            messageBody: message.body
                        )
                    } label: {
                        OutgoingMailRow(
                            recipient: displayName(for: message.destination),
                            messageBody: message.body,
                            state: message.state,
                            deliveredAt: message.deliveredAt,
                            openedAt: message.openedAt
                        )
                    }
                }
            }
        }
        .overlay {
            if mailbox == .inbox && incomingMessages.isEmpty {
                ContentUnavailableView("No Preserved Messages", systemImage: "tray")
            } else if mailbox == .outbox && mailboxMetadata.outgoingMessages.isEmpty {
                ContentUnavailableView("No Preserved Messages", systemImage: "paperplane")
            }
        }
        .navigationTitle(mailbox.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Context Actions", systemImage: "ellipsis.circle") {
                    Button("Delete Context and Data", systemImage: "trash", role: .destructive) {
                        confirmingDeletion = true
                    }
                }
            }
        }
        .confirmationDialog("Delete Context and All Data?", isPresented: $confirmingDeletion) {
            Button("Delete \(contextName) and Data", role: .destructive) {
                dismiss()
                Task { await deleteContext(contextID) }
            }
            Button("Keep Context", role: .cancel) {}
        } message: {
            Text("This permanently deletes every locally stored message, mailbox setting, and data store belonging to \(contextName). This cannot be undone and reconnecting later will create a new Context.")
        }
    }

    private func displayName(for address: UUID) -> String {
        mailboxMetadata.recipients.first(where: { $0.id == address })?.name ?? address.uuidString
    }
}

private struct IOSMailboxMessageListView: View {
    @Environment(\.scenePhase) private var scenePhase
    let selection: MailboxSelection
    let networkName: String
    let networkConnectivity: ActiveNetworkConnectivity
    let appleNetworkSnapshot: AppleNetworkSnapshot
    let model: MessageComposerModel
    let switchNetwork: (NetworkProfileID) -> Void
    let refresh: () async -> Void
    @State private var showingComposer = false
    @State private var inboxFilter = InboxFilter.all
    @State private var searchText = ""
    @State private var visibleIncomingMessages: [IncomingMessage] = []
    @State private var refreshPhase = NetworkRefreshPhase.idle
    @State private var refreshResultDismissTask: Task<Void, Never>?
    @State private var pullStage = NetworkPullStage.hidden
    @State private var armedHapticSequence = 0
    @State private var presentedMessageInfo: PresentedMessageInfo?

    var body: some View {
        List {
            if refreshPhase == .idle && pullStage != .hidden {
                NetworkPeekRow(
                    stage: pullStage,
                    appleNetworkSnapshot: appleNetworkSnapshot,
                    beakrNetworkName: networkName,
                    connectivity: networkConnectivity
                )
            }

            MailboxPageTitleRow(title: selection.mailbox.title)

            switch selection.mailbox {
            case .inbox:
                Section {
                    EmptyView()
                } header: {
                    MailboxSummaryHeader(
                        networkName: networkName,
                        networkConnectivity: networkConnectivity,
                        mailbox: .inbox,
                        unreadCount: model.unreadIncomingCount,
                        queuedCount: 0,
                        messageCount: model.incomingMessages.count,
                        lastUpdated: model.incomingMessages.first?.receivedAt
                    )
                }

                ForEach(visibleIncomingMessages) { message in
                    incomingMessageLink(for: message)
                }
            case .outbox:
                Section {
                    EmptyView()
                } header: {
                    MailboxSummaryHeader(
                        networkName: networkName,
                        networkConnectivity: networkConnectivity,
                        mailbox: .outbox,
                        unreadCount: 0,
                        queuedCount: model.outgoingMessages.lazy.filter {
                            $0.state == .queued || $0.state == .sending
                        }.count,
                        messageCount: model.outgoingMessages.count,
                        lastUpdated: model.outgoingMessages.first.flatMap { $0.openedAt ?? $0.deliveredAt }
                    )
                }

                ForEach(model.outgoingMessages) { message in
                    NavigationLink {
                        MailMessageDetail(
                            heading: model.displayName(for: message.destination),
                            address: message.destination.uuidString,
                            metadata: message.state.detailTitle,
                            messageBody: message.body
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            OutgoingMailRow(
                                recipient: model.displayName(for: message.destination),
                                messageBody: message.body,
                                state: message.state,
                                deliveredAt: message.deliveredAt,
                                openedAt: message.openedAt
                            )
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .navigationLinkIndicatorVisibility(.hidden)
                    .contextMenu {
                        ControlGroup {
                            Button("Send Again", systemImage: "paperplane") {
                                model.prepareResend(to: message.destination, body: message.body)
                                showingComposer = true
                            }

                            Button("Forward", systemImage: "arrowshape.turn.up.right") {
                                model.prepareForward(body: message.body)
                                showingComposer = true
                            }
                        }
                        .controlGroupStyle(.palette)

                        Divider()

                        Button("Message Info", systemImage: "info.circle") {
                            presentedMessageInfo = .outgoing(message)
                        }
                    } preview: {
                        MessageContextPreview(
                            heading: model.displayName(for: message.destination),
                            metadata: message.state.detailTitle,
                            subject: nil,
                            messageBody: message.body
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await model.deleteOutgoingMessage(id: message.id) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.background)
        .refreshable { await performNetworkRefresh() }
        .networkPullTracking(
            isRefreshing: refreshPhase == .refreshing,
            pullStage: $pullStage,
            armedHapticSequence: $armedHapticSequence
        )
        .sensoryFeedback(.impact(weight: .light), trigger: armedHapticSequence)
        .overlay {
            if selection.mailbox == .inbox && visibleIncomingMessages.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty && inboxFilter == .all ? "No Messages" : "No Matching Messages",
                    systemImage: searchText.isEmpty && inboxFilter == .all ? "tray" : "line.3.horizontal.decrease.circle"
                )
            } else if selection.mailbox == .outbox && model.outgoingMessages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "paperplane")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selection.mailbox == .inbox {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        Picker("Filter", selection: $inboxFilter) {
                            ForEach(InboxFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                    } label: {
                        Image(systemName: inboxFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter Inbox")

                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search Inbox")

                    Button("Compose", systemImage: "square.and.pencil") {
                        showingComposer = true
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Compose", systemImage: "square.and.pencil") {
                        showingComposer = true
                    }
                }
            }
        }
        .onAppear {
            if let networkID = selection.networkID {
                switchNetwork(networkID)
            }
            updateVisibleIncomingMessages()
        }
        .onChange(of: model.incomingMessages) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: model.readMessageIDs) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: model.flaggedMessageIDs) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: inboxFilter) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: searchText) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelNetworkRefreshPresentation()
        }
        .sheet(isPresented: $showingComposer) {
            IOSMessageComposerView(model: model, dismiss: { showingComposer = false })
        }
        .sheet(item: $presentedMessageInfo) { info in
            MessageInfoView(info: info)
        }
    }

    private func incomingMessageLink(for message: IncomingMessage) -> some View {
        NavigationLink {
            MailMessageDetail(
                heading: message.source.map(model.displayName) ?? "Unknown Sender",
                address: message.source?.uuidString,
                metadata: message.receivedAt.formatted(date: .abbreviated, time: .shortened),
                messageBody: message.body
            )
            .task { await model.openIncomingMessage(message) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                IncomingMailRow(
                    sender: message.source.map(model.displayName) ?? "Unknown Sender",
                    subject: message.subject,
                    preview: message.preview,
                    receivedAt: message.receivedAt,
                    isRead: model.isRead(message.id),
                    isFlagged: model.isFlagged(message.id)
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .simultaneousGesture(TapGesture().onEnded {
            // Commit the unread-to-read transition at selection time. This
            // avoids depending on the destination view's appearance timing.
            model.setRead(true, messageID: message.id)
            Task { await model.openIncomingMessage(message) }
        })
        .swipeActions(edge: .leading) {
            Button(model.isRead(message.id) ? "Unread" : "Read") {
                model.setRead(!model.isRead(message.id), messageID: message.id)
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.deleteIncomingMessage(id: message.id) }
            }

            Button(model.isFlagged(message.id) ? "Unflag" : "Flag") {
                model.toggleFlag(messageID: message.id)
            }
            .tint(.orange)
        }
        .contextMenu {
            ControlGroup {
                if let source = message.source, model.isAddressable(source) {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") {
                        model.prepareReply(to: source)
                        showingComposer = true
                    }
                }

                Button("Forward", systemImage: "arrowshape.turn.up.right") {
                    model.prepareForward(body: message.body)
                    showingComposer = true
                }
            }
            .controlGroupStyle(.palette)

            Divider()

            Button(
                model.isRead(message.id) ? "Mark as Unread" : "Mark as Read",
                systemImage: model.isRead(message.id) ? "envelope.badge" : "envelope.open"
            ) {
                model.setRead(!model.isRead(message.id), messageID: message.id)
            }

            Button(
                model.isFlagged(message.id) ? "Unflag" : "Flag",
                systemImage: model.isFlagged(message.id) ? "flag.slash" : "flag"
            ) {
                model.toggleFlag(messageID: message.id)
            }

            Divider()

            Button("Message Info", systemImage: "info.circle") {
                presentedMessageInfo = .incoming(message)
            }
        } preview: {
            MessageContextPreview(
                heading: message.source.map(model.displayName) ?? "Unknown Sender",
                metadata: message.receivedAt.formatted(date: .abbreviated, time: .shortened),
                subject: message.subject,
                messageBody: message.body
            )
        }
    }

    private func updateVisibleIncomingMessages() {
        visibleIncomingMessages = model.incomingMessages.filter { message in
            let matchesFilter = switch inboxFilter {
            case .all: true
            case .unread: !model.isRead(message.id)
            case .flagged: model.isFlagged(message.id)
            }
            guard matchesFilter else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let sender = message.source.map(model.displayName) ?? "Unknown Sender"
            return sender.localizedCaseInsensitiveContains(query)
                || message.subject.localizedCaseInsensitiveContains(query)
                || message.body.localizedCaseInsensitiveContains(query)
        }
    }

    private func performNetworkRefresh() async {
        guard refreshPhase != .refreshing else { return }
        refreshResultDismissTask?.cancel()
        pullStage = .hidden
        refreshPhase = .refreshing
        await refresh()
        guard !Task.isCancelled else { return }
        refreshPhase = .finished
        refreshResultDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            refreshPhase = .idle
        }
    }

    private func cancelNetworkRefreshPresentation() {
        refreshResultDismissTask?.cancel()
        refreshResultDismissTask = nil
        refreshPhase = .idle
    }
}

private enum PresentedMessageInfo: Identifiable {
    case incoming(IncomingMessage)
    case outgoing(OutgoingMessage)

    var id: UUID {
        switch self {
        case .incoming(let message): message.id
        case .outgoing(let message): message.id
        }
    }
}

private struct MessageInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let info: PresentedMessageInfo

    var body: some View {
        NavigationStack {
            Form {
                switch info {
                case .incoming(let message):
                    Section("Message") {
                        valueRow("Correlation ID", message.id.uuidString)
                        valueRow("Received", message.receivedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if let provenance = message.provenance {
                        Section("Network Route") {
                            valueRow("Network ID", provenance.networkID.uuidString)
                            valueRow("Profile ID", provenance.profileID.uuidString)
                            valueRow("Session ID", provenance.sessionID.uuidString)
                            valueRow("Source Device", provenance.sourceDeviceID.uuidString)
                            valueRow("Destination Device", provenance.destinationDeviceID.uuidString)
                        }
                        Section("Authority") {
                            valueRow("Authority ID", provenance.authorityID.uuidString)
                            valueRow("Authority Endpoint", provenance.authorityEndpoint)
                            valueRow("Local Credential", provenance.localCredentialID.uuidString)
                        }
                        Section("Transport") {
                            valueRow("Envelope Message ID", provenance.storageMessageID.uuidString)
                            valueRow("Envelope Created", provenance.envelopeCreatedAt.formatted(date: .abbreviated, time: .standard))
                        }
                    } else {
                        Section("Network Route") {
                            Text("Provenance was not captured for this earlier message.")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .outgoing(let message):
                    Section("Message") {
                        valueRow("Correlation ID", message.id.uuidString)
                        valueRow("Destination Device", message.destination.uuidString)
                        valueRow("State", message.state.detailTitle)
                        if let deliveredAt = message.deliveredAt {
                            valueRow("Delivered", deliveredAt.formatted(date: .abbreviated, time: .standard))
                        }
                        if let openedAt = message.openedAt {
                            valueRow("Opened", openedAt.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                    Section("Network Route") {
                        if let provenance = message.provenance {
                            valueRow("Network ID", provenance.networkID.uuidString)
                            valueRow("Profile ID", provenance.profileID.uuidString)
                            valueRow("Session ID", provenance.sessionID.uuidString)
                            valueRow("Source Device", provenance.sourceDeviceID.uuidString)
                            valueRow("Destination Device", provenance.destinationDeviceID.uuidString)
                        } else {
                            Text("Provenance was not captured for this earlier message.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let provenance = message.provenance {
                        Section("Authority") {
                            valueRow("Authority ID", provenance.authorityID.uuidString)
                            valueRow("Authority Endpoint", provenance.authorityEndpoint)
                            valueRow("Local Credential", provenance.localCredentialID.uuidString)
                        }
                        Section("Delivery") {
                            valueRow("Envelope Message ID", provenance.storageMessageID.uuidString)
                            valueRow("Queued", provenance.queuedAt.formatted(date: .abbreviated, time: .standard))
                            valueRow("Attempts", String(message.deliveryAttemptCount ?? 0))
                            if let failure = message.lastDeliveryFailure {
                                valueRow("Last Failure", failure)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Message Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func valueRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct MailboxPageTitleRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var status: LocalizedStringResource? = nil
    var statusDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())

            if let subtitle {
                Text(subtitle)
                    .font(.title2.bold())
                    .padding(.top, 18)
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else if let statusDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Group {
                        if context.date.timeIntervalSince(statusDate) < 60 {
                            Text("Updated Just Now")
                        } else {
                            Text("Updated \(statusDate, format: .relative(presentation: .named))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NetworkMailboxHeader: View {
    let name: String
    let isActive: Bool
    let connectivity: ActiveNetworkConnectivity
    let topSpacingAdjustment: CGFloat

    var body: some View {
        Label {
            Text(name)
        } icon: {
            Image(systemName: "network")
        }
        .foregroundStyle(isActive ? networkNameColor : Color.secondary)
        .textCase(nil)
        .padding(.top, topSpacingAdjustment)
        .accessibilityLabel("Network: \(name)")
        .accessibilityValue(isActive ? connectivity.compactStatusTitle : "Inactive")
    }

    private var networkNameColor: Color {
        switch connectivity {
        case .inactive:
            return .secondary
        case .connected:
            return .green
        case .reconnecting, .discoveringPeers, .readyNoPeers, .failed:
            return .blue
        }
    }
}

private enum NetworkRefreshPhase: Equatable {
    case idle
    case refreshing
    case finished
}

private enum NetworkPullStage: Equatable {
    case hidden
    case peek
    case armed
}

private struct NetworkPullTrackingModifier: ViewModifier {
    let isRefreshing: Bool
    @Binding var pullStage: NetworkPullStage
    @Binding var armedHapticSequence: Int
    @State private var peekDismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: NetworkPullStage.self) { geometry in
                let pullDistance = max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
                if pullDistance >= 68 {
                    return .armed
                }
                if pullDistance >= 18 {
                    return .peek
                }
                return .hidden
            } action: { oldStage, newStage in
                guard !isRefreshing else {
                    peekDismissTask?.cancel()
                    pullStage = .hidden
                    return
                }
                if newStage == .hidden, oldStage == .peek {
                    peekDismissTask?.cancel()
                    peekDismissTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.5))
                        guard !Task.isCancelled, !isRefreshing else { return }
                        pullStage = .hidden
                    }
                } else {
                    peekDismissTask?.cancel()
                    peekDismissTask = nil
                    pullStage = newStage
                }
                if oldStage != .armed, newStage == .armed {
                    armedHapticSequence += 1
                }
            }
            .onDisappear {
                peekDismissTask?.cancel()
            }
    }
}

private extension View {
    func networkPullTracking(
        isRefreshing: Bool,
        pullStage: Binding<NetworkPullStage>,
        armedHapticSequence: Binding<Int>
    ) -> some View {
        modifier(NetworkPullTrackingModifier(
            isRefreshing: isRefreshing,
            pullStage: pullStage,
            armedHapticSequence: armedHapticSequence
        ))
    }
}

private struct NetworkPeekRow: View {
    let stage: NetworkPullStage
    let appleNetworkSnapshot: AppleNetworkSnapshot
    let beakrNetworkName: String
    let connectivity: ActiveNetworkConnectivity

    var body: some View {
        VStack(spacing: 3) {
            if stage == .armed {
                Label("Release to Refresh", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text(appleNetworkSnapshot.appleNetworkDescription)
                    .font(.subheadline.weight(.semibold))
                Text("Beakr'Net - \(beakrNetworkName)")
                    .foregroundStyle(.primary)
                Text("Status: \(connectivity.peekDescription)")
                    .foregroundStyle(connectivity.statusColor)
                Text("Internet route: \(appleNetworkSnapshot.internetRoute.description)")
                    .foregroundStyle(.secondary)
                Text("Last checked \(appleNetworkSnapshot.checkedAt, format: .relative(presentation: .named))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(minHeight: 104)
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

private struct AppleNetworkSnapshot: Equatable {
    enum InternetRoute: Equatable {
        case wifi
        case cellular
        case other
        case unavailable

        var description: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .cellular: "Cellular"
            case .other: "Other"
            case .unavailable: "Unavailable"
            }
        }
    }

    let wifiName: String?
    let internetRoute: InternetRoute
    let checkedAt: Date

    static let unknown = AppleNetworkSnapshot(
        wifiName: nil,
        internetRoute: .unavailable,
        checkedAt: Date()
    )

    var appleNetworkDescription: String {
        if let wifiName {
            return "Wi-Fi: \(wifiName)"
        }
        if internetRoute == .wifi {
            return "Wi-Fi connected · Name unavailable"
        }
        return "Wi-Fi network not identified"
    }

    static func capture() async -> AppleNetworkSnapshot {
        async let wifiName = currentWiFiName()
        async let internetRoute = CurrentInternetRouteProbe().route()
        return await AppleNetworkSnapshot(
            wifiName: wifiName,
            internetRoute: internetRoute,
            checkedAt: Date()
        )
    }

    private static func currentWiFiName() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}

private final class CurrentInternetRouteProbe: @unchecked Sendable {
    func route() async -> AppleNetworkSnapshot.InternetRoute {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "net.beakr.internet-route-probe")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                monitor.pathUpdateHandler = { path in
                    let route: AppleNetworkSnapshot.InternetRoute
                    if path.status != .satisfied {
                        route = .unavailable
                    } else if path.usesInterfaceType(.wifi) {
                        route = .wifi
                    } else if path.usesInterfaceType(.cellular) {
                        route = .cellular
                    } else {
                        route = .other
                    }
                    monitor.cancel()
                    continuation.resume(returning: route)
                }
                monitor.start(queue: queue)
            }
        } onCancel: {
            monitor.cancel()
        }
    }
}

private extension ActiveNetworkConnectivity {
    var peekDescription: String {
        switch self {
        case .inactive: "Inactive"
        case .reconnecting: "Checking Local Network"
        case .discoveringPeers: "Discovering devices"
        case .readyNoPeers: "No devices online"
        case .connected(let peerCount): peerCount == 1 ? "Connected to 1 device" : "Connected to \(peerCount) devices"
        case .failed: "Unavailable"
        }
    }
}

private struct MessageContextPreview: View {
    let heading: String
    let metadata: String
    let subject: String?
    let messageBody: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let subject, !subject.isEmpty {
                Text(subject)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }

            Divider()

            Text(messageBody)
                .font(.body)
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(idealWidth: 330, maxWidth: 380, alignment: .leading)
        .background(.background)
    }
}

private struct IOSMessageComposerView: View {
    @Bindable var model: MessageComposerModel
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                MessageComposerSection(
                    recipients: model.addressableRecipients,
                    onlineRecipientIDs: model.onlineRecipientIDs,
                    destinationID: $model.destinationID,
                    messageText: $model.messageText,
                    canSend: model.canSend,
                    send: {
                        Task {
                            await model.send()
                            dismiss()
                        }
                    }
                )
            }
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                }
            }
        }
    }
}

private struct IOSBeakrManagementView: View {
    let model: MessageComposerModel
    @Bindable var bootstrap: NodeBootstrapModel
    let dismiss: () -> Void
    @State private var showingInvitationScanner = false
    @State private var pendingScannedInvitation: String?
    @State private var invitationReview: InvitationReview?
    @State private var repairTargetNetworkID: NetworkID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        IOSNetworkManagerView(
                            bootstrap: bootstrap,
                            scanInvitation: scanInvitation,
                            reviewInvitation: presentInvitationReview,
                            scanRepairInvitation: scanRepairInvitation,
                            pasteRepairInvitation: pasteRepairInvitation
                        )
                    } label: {
                        Label("Networks", systemImage: "network")
                            .badge(bootstrap.networks.count)
                    }

                    NavigationLink {
                        IOSDeviceSettingsView(bootstrap: bootstrap)
                    } label: {
                        Label("This Device", systemImage: "iphone")
                    }
                }

                Section {
                    NavigationLink {
                        Form {
                            RecipientManagementSection(
                                recipients: model.recipients,
                                add: model.addRecipient,
                                rename: model.renameRecipient,
                                remove: model.removeRecipient
                            )
                        }
                        .navigationTitle("Contacts")
                    } label: {
                        Label("Contacts", systemImage: "person.2")
                    }
                }
            }
            .navigationTitle("Beakr Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
            .sheet(isPresented: $showingInvitationScanner, onDismiss: presentScannedInvitationReview) {
                InvitationScannerSheet { invitation in
                    pendingScannedInvitation = invitation
                    showingInvitationScanner = false
                }
            }
            .sheet(item: $invitationReview) { review in
                InvitationReviewSheet(
                    bootstrap: bootstrap,
                    review: review,
                    dismiss: { invitationReview = nil }
                )
            }
        }
    }

    private func scanInvitation() {
        repairTargetNetworkID = nil
        showingInvitationScanner = true
    }

    private func scanRepairInvitation(_ networkID: NetworkID) {
        repairTargetNetworkID = networkID
        bootstrap.prepareForNetworkJoin()
        showingInvitationScanner = true
    }

    private func pasteRepairInvitation(_ networkID: NetworkID) {
        repairTargetNetworkID = networkID
        bootstrap.prepareForNetworkJoin()
        guard let invitation = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !invitation.isEmpty else {
            repairTargetNetworkID = nil
            bootstrap.networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "No Invitation Found",
                message: "Copy a current invitation for this Beakr'Net, then choose Repair Network Access again."
            )
            return
        }
        presentInvitationReview(invitation)
    }

    private func presentScannedInvitationReview() {
        guard let invitation = pendingScannedInvitation else { return }
        pendingScannedInvitation = nil
        presentInvitationReview(invitation)
    }

    private func presentInvitationReview(_ invitation: String) {
        guard let review = bootstrap.invitationReview(for: invitation) else {
            repairTargetNetworkID = nil
            return
        }
        if let repairTargetNetworkID,
           review.networkID != repairTargetNetworkID {
            self.repairTargetNetworkID = nil
            bootstrap.networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Invitation Is for Another Network",
                message: "Repair requires a current invitation for the selected Beakr'Net. No network profile was changed."
            )
            return
        }
        repairTargetNetworkID = nil
        invitationReview = review
    }
}

private struct IOSNetworkManagerView: View {
    @Bindable var bootstrap: NodeBootstrapModel
    let scanInvitation: () -> Void
    let reviewInvitation: (String) -> Void
    let scanRepairInvitation: (NetworkID) -> Void
    let pasteRepairInvitation: (NetworkID) -> Void

    var body: some View {
        List {
            Section {
                if bootstrap.networks.isEmpty {
                    ContentUnavailableView(
                        "No Networks",
                        systemImage: "network.slash",
                        description: Text("Scan an invitation or enter one to join a network.")
                    )
                } else {
                    ForEach(bootstrap.networks) { network in
                    NavigationLink {
                        IOSNetworkDetailView(
                            bootstrap: bootstrap,
                            networkID: network.id,
                            scanRepairInvitation: scanRepairInvitation,
                            pasteRepairInvitation: pasteRepairInvitation
                        )
                    } label: {
                        HStack {
                            Image(systemName: network.canManageNetwork ? "network.badge.shield.half.filled" : "network")
                                .foregroundStyle(network.isActive ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(network.displayName)
                                Text(network.isActive ? bootstrap.activeNetworkStatusTitle : "Inactive")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if network.isActive {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(bootstrap.activeNetworkConnectivity.statusColor)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    }
                }
            } footer: {
                Text("Only one network is active for messaging at a time. Inactive networks remain saved on this device.")
            }

            Section {
                Button("Scan & Join", systemImage: "qrcode.viewfinder") {
                    bootstrap.prepareForNetworkJoin()
                    scanInvitation()
                }
                .disabled(bootstrap.state == .joiningNetwork)

                Button("Paste & Join", systemImage: "doc.on.clipboard") {
                    pasteInvitationAndJoin()
                }
                .disabled(bootstrap.state == .joiningNetwork)
            } header: {
                Text("Add Network")
            } footer: {
                Text("Scan or paste an invitation to join or repair access to an existing Beakr'Net.")
            }

            if bootstrap.state == .joiningNetwork || bootstrap.state == .failed {
                DeviceOperationStatusSection(
                    state: bootstrap.state,
                    statusMessage: bootstrap.statusMessage
                )
            }
        }
        .navigationTitle("Networks")
        .refreshable { await bootstrap.reconnectActiveNetwork() }
        .networkJoinAlert(
            $bootstrap.networkJoinAlert,
            confirmCollision: { Task { await bootstrap.confirmCollidingNetworkJoin() } },
            confirmReattachment: { Task { await bootstrap.confirmContextReattachment() } }
        )
    }

    private func pasteInvitationAndJoin() {
        bootstrap.prepareForNetworkJoin()
        guard let pastedInvitation = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !pastedInvitation.isEmpty else {
            bootstrap.networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "No Invitation Found",
                message: "Copy a Beakr invitation, then choose Paste & Join again."
            )
            return
        }
        bootstrap.joinInvitationJSON = pastedInvitation
        reviewInvitation(pastedInvitation)
    }
}

private struct InvitationReviewSheet: View {
    @Bindable var bootstrap: NodeBootstrapModel
    let review: InvitationReview
    let dismiss: () -> Void
    @State private var isJoining = false
    @State private var result: NetworkJoinAlert?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    InvitationReviewHeader(
                        networkName: review.networkDisplayName,
                        authorityHost: review.authorityURL.host ?? review.authorityURL.absoluteString,
                        isExpired: review.isExpired()
                    )
                    InvitationReviewTimingCard(review: review)
                    if review.isExpired() {
                        ExpiredInvitationRecoveryCard(
                            review: review,
                            deviceName: bootstrap.deviceDisplayName
                        )
                    }
                    InvitationReviewTechnicalDetails(review: review)
                    if isJoining {
                        InvitationJoinProgress(statusMessage: bootstrap.statusMessage)
                    }
                    if let result {
                        InvitationJoinResultCard(result: result)
                    }
                }
                .padding()
            }
            .navigationTitle("Beakr'Net Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                InvitationReviewActions(
                    isExpired: review.isExpired(),
                    isJoining: isJoining,
                    result: result,
                    reject: reject,
                    accept: accept,
                    acceptCollision: acceptCollision,
                    acceptReattachment: acceptReattachment,
                    repairExistingNetwork: repairExistingNetwork,
                    useExistingNetwork: useExistingNetwork,
                    done: dismiss
                )
            }
            .interactiveDismissDisabled(isJoining)
        }
    }

    private func reject() {
        bootstrap.rejectInvitation(review)
        dismiss()
    }

    private func accept() {
        guard !isJoining else { return }
        isJoining = true
        result = nil
        Task {
            await bootstrap.acceptInvitation(review)
            result = bootstrap.networkJoinAlert
            bootstrap.networkJoinAlert = nil
            if result?.invitationAccepted == true,
               UIPasteboard.general.string == review.invitationJSON {
                UIPasteboard.general.items = []
            }
            isJoining = false
        }
    }

    private func acceptCollision() {
        guard let result, result.suggestedName != nil else { return }
        bootstrap.networkJoinAlert = result
        isJoining = true
        self.result = nil
        Task {
            await bootstrap.confirmCollidingNetworkJoin()
            self.result = bootstrap.networkJoinAlert
            bootstrap.networkJoinAlert = nil
            isJoining = false
        }
    }

    private func acceptReattachment() {
        guard let result, result.reattachmentContextID != nil else { return }
        bootstrap.networkJoinAlert = result
        isJoining = true
        self.result = nil
        Task {
            await bootstrap.confirmContextReattachment()
            self.result = bootstrap.networkJoinAlert
            bootstrap.networkJoinAlert = nil
            isJoining = false
        }
    }

    private func useExistingNetwork() {
        guard let profileID = result?.existingProfileID else { return }
        isJoining = true
        result = nil
        Task {
            await bootstrap.useExistingNetwork(profileID)
            result = bootstrap.networkJoinAlert
            bootstrap.networkJoinAlert = nil
            isJoining = false
        }
    }

    private func repairExistingNetwork() {
        guard let profileID = result?.existingProfileID else { return }
        isJoining = true
        result = nil
        Task {
            await bootstrap.repairExistingNetwork(using: review, profileID: profileID)
            result = bootstrap.networkJoinAlert
            bootstrap.networkJoinAlert = nil
            if result?.invitationAccepted == true,
               UIPasteboard.general.string == review.invitationJSON {
                UIPasteboard.general.items = []
            }
            isJoining = false
        }
    }
}

private struct InvitationReviewHeader: View {
    let networkName: String
    let authorityHost: String
    let isExpired: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isExpired ? "clock.badge.exclamationmark.fill" : "network.badge.shield.half.filled")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(isExpired ? .red : .blue)
                .symbolRenderingMode(.hierarchical)
            Text(networkName)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(isExpired
                 ? "This invitation has expired."
                 : "\(authorityHost) is inviting this iPhone to join this Beakr'Net.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label(isExpired ? "Expired" : "Ready for Review", systemImage: isExpired ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isExpired ? .red : .green)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background((isExpired ? Color.red : Color.green).opacity(0.12), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct InvitationReviewTimingCard: View {
    let review: InvitationReview

    var body: some View {
        VStack(spacing: 0) {
            InvitationReviewValueRow(title: "Valid for", value: validityDescription)
            Divider()
            InvitationReviewDateRow(title: "Issued", date: review.issuedAt)
            Divider()
            InvitationReviewDateRow(title: "Received", date: review.receivedAt)
            Divider()
            InvitationReviewDateRow(title: "Expires", date: review.expiresAt)
        }
        .padding(.horizontal)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var validityDescription: String {
        let seconds = max(0, Int(review.validity.rounded()))
        if seconds.isMultiple(of: 60) {
            return String(localized: "\(seconds / 60) minutes")
        }
        return String(localized: "\(seconds) seconds")
    }
}

private struct InvitationReviewDateRow: View {
    let title: LocalizedStringResource
    let date: Date

    var body: some View {
        LabeledContent {
            Text(date, format: .dateTime.year().month().day().hour().minute().second())
                .multilineTextAlignment(.trailing)
        } label: {
            Text(title)
        }
        .padding(.vertical, 12)
    }
}

private struct InvitationReviewValueRow: View {
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)

            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

private struct InvitationReviewTechnicalDetails: View {
    let review: InvitationReview

    var body: some View {
        DisclosureGroup("Technical Details") {
            VStack(spacing: 0) {
                InvitationReviewValueRow(title: "Network ID", value: review.networkID.rawValue.uuidString)
                Divider()
                InvitationReviewValueRow(title: "Authority ID", value: review.authorityID.rawValue.uuidString)
                Divider()
                InvitationReviewValueRow(title: "Authority Address", value: review.authorityURL.absoluteString)
                Divider()
                InvitationReviewValueRow(title: "Environment", value: review.environment)
                Divider()
                InvitationReviewValueRow(title: "Services", value: review.serviceScopes.formatted())
            }
            .font(.footnote)
            .textSelection(.enabled)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ExpiredInvitationRecoveryCard: View {
    let review: InvitationReview
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Request a New Invitation", systemImage: "paperplane.circle.fill")
                .font(.headline)
                .foregroundStyle(.blue)

            Text("Send a replacement request to the person who manages this Beakr'Net. The expired invitation remains unusable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ShareLink(item: requestText) {
                Label("Send Invitation Request", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var requestText: String {
        """
        Please send \(deviceName) a new Beakr'Net invitation.

        Network: \(review.networkDisplayName)
        Network ID: \(review.networkID.rawValue.uuidString)
        Authority: \(review.authorityURL.absoluteString)
        Expired invitation ID: \(review.id.uuidString)
        Expired: \(review.expiresAt.formatted(date: .abbreviated, time: .standard))
        """
    }
}

private struct InvitationJoinProgress: View {
    let statusMessage: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text("Accepting Invitation")
                    .font(.headline)
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct InvitationJoinResultCard: View {
    let result: NetworkJoinAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: resultSystemImage)
                .font(.title2)
            VStack(alignment: .leading, spacing: 5) {
                Text(result.title)
                    .font(.headline)
                Text(result.message)
                    .font(.subheadline)
            }
            Spacer()
        }
        .foregroundStyle(resultColor)
        .padding()
        .background(resultColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var resultColor: Color {
        if let connectivity = result.connectivity {
            return connectivity.statusColor
        }
        return result.succeeded ? .green : .orange
    }

    private var resultSystemImage: String {
        if result.connectivity == .readyNoPeers {
            return "network"
        }
        return result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
}

private struct InvitationReviewActions: View {
    let isExpired: Bool
    let isJoining: Bool
    let result: NetworkJoinAlert?
    let reject: () -> Void
    let accept: () -> Void
    let acceptCollision: () -> Void
    let acceptReattachment: () -> Void
    let repairExistingNetwork: () -> Void
    let useExistingNetwork: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if result?.succeeded == true {
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if result?.reattachmentContextID != nil {
                Button("Reconnect Preserved Context", action: acceptReattachment)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isJoining)
                Button("Keep Context Archived", action: done)
                    .disabled(isJoining)
            } else if result?.suggestedName != nil {
                Button("Accept With Suggested Name", action: acceptCollision)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Reject Invitation", role: .destructive, action: reject)
            } else if result?.existingProfileID != nil {
                Button("Repair Existing Network", action: repairExistingNetwork)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isJoining)
                Button("Try Reconnecting", action: useExistingNetwork)
                    .disabled(isJoining)
                Button("Cancel", action: done)
                    .disabled(isJoining)
            } else if isExpired {
                Button("Reject Expired Invitation", role: .destructive, action: reject)
                    .controlSize(.large)
            } else if result != nil {
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Accept Invitation", action: accept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isJoining)
                Button("Reject Invitation", role: .destructive, action: reject)
                    .disabled(isJoining)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }
}

private struct IOSNetworkDetailView: View {
    @Bindable var bootstrap: NodeBootstrapModel
    let networkID: NetworkProfileID
    let scanRepairInvitation: (NetworkID) -> Void
    let pasteRepairInvitation: (NetworkID) -> Void
    @State private var confirmingDeparture = false
    @State private var choosingRepairInvitation = false
    @State private var editedNetworkName = ""
    @State private var isSavingNetworkName = false
    @State private var isRefreshingConnection = false
    @State private var didCompleteConnectionRefresh = false

    private var network: NetworkSummary? {
        bootstrap.networks.first { $0.id == networkID }
    }

    var body: some View {
        Form {
            if let network {
                Section("Beakr'Net Parameters") {
                    LabeledContent("Network Name") {
                        HStack {
                            TextField("Network Name", text: $editedNetworkName)
                                .multilineTextAlignment(.trailing)
                                .submitLabel(.done)
                                .onSubmit { saveNetworkName(network) }
                            Button("Save") { saveNetworkName(network) }
                                .disabled(!canSaveName(for: network) || isSavingNetworkName)
                        }
                    }
                    NetworkStatusDisclosure(
                        connectivity: network.isActive ? bootstrap.activeNetworkConnectivity : .inactive,
                        knownDeviceCount: network.isActive ? bootstrap.networkMembers.count : 0,
                        onlineDeviceCount: network.isActive ? bootstrap.onlineMemberIDs.count : 0
                    )
                    if network.isActive {
                        Button(action: refreshConnection) {
                            HStack(spacing: 8) {
                                if isRefreshingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isRefreshingConnection ? "Refreshing Connection…" : "Refresh Connection")
                            }
                        }
                        .disabled(isRefreshingConnection)

                        if didCompleteConnectionRefresh && !isRefreshingConnection {
                            Label(
                                "Refresh complete: \(bootstrap.activeNetworkConnectivity.compactStatusTitle)",
                                systemImage: bootstrap.activeNetworkConnectivity == .failed
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(bootstrap.activeNetworkConnectivity.statusColor)
                        }

                    }
                    Button("Repair Network Access…", systemImage: "wrench.and.screwdriver") {
                        choosingRepairInvitation = true
                    }
                    NetworkAccessRow(canManageNetwork: network.canManageNetwork)
                    NetworkAuthorityRow(
                        deviceName: network.isActive ? bootstrap.activeAuthorityDeviceName : nil,
                        endpoint: network.isActive ? bootstrap.activeAuthorityEndpoint : nil,
                        isHostedHere: network.isHostingAuthority
                    )
                    LabeledContent("Services", value: network.canExchangeMessages ? "Messaging" : "Unavailable")
                    LabeledContent("Network ID") {
                        Text(network.networkID.rawValue.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    if !network.isActive {
                        Button("Make Active", systemImage: "checkmark.circle") {
                            Task { await bootstrap.switchNetwork(to: network.id) }
                        }
                        .disabled(bootstrap.state != .ready)
                    }
                }

                Section("Addressable Devices") {
                    NetworkAddressesContent(
                        localName: bootstrap.deviceDisplayName,
                        localID: bootstrap.nodeID,
                        members: network.isActive ? bootstrap.networkMembers : [],
                        onlineMemberIDs: network.isActive ? bootstrap.onlineMemberIDs : [],
                        isLocalDeviceOnline: network.isActive
                    )
                }

                if network.canManageNetwork {
                    InviteDeviceSection(
                        invitation: network.isActive ? bootstrap.invitationJSON : "",
                        create: { Task { await bootstrap.createInvitation() } }
                    )
                    .disabled(!network.isActive || !bootstrap.canCreateInvitations)
                    if !network.isHostingAuthority {
                        Text("This iPhone has management authorization. Remote authority operations will become available when the authority control API is enabled.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Invitations") {
                        ContentUnavailableView(
                            "Invitations Managed by the Authority",
                            systemImage: "qrcode",
                            description: Text("This iPhone is a network member. Invitations must be created by a device holding the network authority.")
                        )
                    }
                }

                Section {
                    Button("Forget Network…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmingDeparture = true
                    }
                }
            } else {
                ContentUnavailableView("Network Unavailable", systemImage: "network.slash")
            }
        }
        .navigationTitle(network?.displayName ?? "Network")
        .onAppear {
            editedNetworkName = network?.displayName ?? ""
        }
        .onChange(of: network?.displayName) { _, newName in
            guard !isSavingNetworkName else { return }
            editedNetworkName = newName ?? ""
        }
        .confirmationDialog("Forget Network on This iPhone?", isPresented: $confirmingDeparture) {
            if let network {
                Button("Forget \(network.displayName)", role: .destructive) {
                    Task { await bootstrap.forgetJoinedNetwork(network.id) }
                }
            }
            Button("Keep Network", role: .cancel) {}
        } message: {
            if let network {
                Text(forgetNetworkMessage(
                    for: network,
                    deviceName: "iPhone",
                    connectivity: bootstrap.activeNetworkConnectivity
                ))
            }
        }
        .confirmationDialog("Repair Network Access?", isPresented: $choosingRepairInvitation) {
            if let network {
                Button("Scan Current Invitation") {
                    scanRepairInvitation(network.networkID)
                }
                Button("Paste Current Invitation") {
                    pasteRepairInvitation(network.networkID)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A fresh invitation from this Beakr'Net authority is required. Messages, settings, and this device's identity will be preserved.")
        }
    }

    private func canSaveName(for network: NetworkSummary) -> Bool {
        let normalizedName = editedNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedName.isEmpty && normalizedName != network.displayName
    }

    private func saveNetworkName(_ network: NetworkSummary) {
        guard canSaveName(for: network), !isSavingNetworkName else { return }
        isSavingNetworkName = true
        Task {
            let saved = await bootstrap.renameLocalNetwork(network.id, to: editedNetworkName)
            if saved {
                editedNetworkName = bootstrap.networks.first(where: { $0.id == network.id })?.displayName
                    ?? editedNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            isSavingNetworkName = false
        }
    }

    private func refreshConnection() {
        guard !isRefreshingConnection else { return }
        isRefreshingConnection = true
        didCompleteConnectionRefresh = false
        Task {
            await bootstrap.reconnectActiveNetwork()
            guard !Task.isCancelled else { return }
            isRefreshingConnection = false
            didCompleteConnectionRefresh = true
        }
    }
}

private struct NetworkStatusDisclosure: View {
    let connectivity: ActiveNetworkConnectivity
    let knownDeviceCount: Int
    let onlineDeviceCount: Int
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LabeledContent("This Device", value: connectivity.localDeviceStatus)
            LabeledContent("Other Devices Online", value: onlineDeviceCount.formatted())
            LabeledContent(
                "Known Devices Offline",
                value: max(knownDeviceCount - onlineDeviceCount, 0).formatted()
            )
            LabeledContent("Connection", value: connectivity.connectionDescription)
        } label: {
            LabeledContent("Status") {
                Text(connectivity.compactStatusTitle)
                    .foregroundStyle(connectivity.statusColor)
            }
        }
    }
}

private struct NetworkAccessRow: View {
    let canManageNetwork: Bool

    var body: some View {
        LabeledContent("Access") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(canManageNetwork ? "Manager" : "Member")
                Text(canManageNetwork
                     ? "Can manage membership and invitations"
                     : "Can exchange messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NetworkAuthorityRow: View {
    let deviceName: String?
    let endpoint: String?
    let isHostedHere: Bool

    var body: some View {
        LabeledContent("Authority Host") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(deviceName ?? (isHostedHere ? "This Device" : "Another Device"))
                if let endpoint {
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct IOSDeviceSettingsView: View {
    @Bindable var bootstrap: NodeBootstrapModel

    var body: some View {
        Form {
            Section {
                TextField("Friendly Name", text: $bootstrap.deviceFriendlyName)
                    .accessibilityLabel("Device Friendly Name")

                LabeledContent("Device ID") {
                    if let nodeID = bootstrap.nodeID {
                        Text(nodeID.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Text("Created after joining a network")
                            .foregroundStyle(.secondary)
                    }
                }

                Label(bootstrap.statusMessage, systemImage: bootstrap.state.systemImage)
                    .foregroundStyle(bootstrap.state == .failed ? .red : .secondary)
            } header: {
                Text("This Device")
            } footer: {
                Text("The friendly name is stored on this iPhone. The device ID uniquely identifies this device on the active Beakr network.")
            }

            if bootstrap.state == .identityReady || bootstrap.state == .enrolling {
                TrustRecoverySection(
                    isWorking: bootstrap.state == .enrolling,
                    enroll: { Task { await bootstrap.enrollAndRecoverTrust() } }
                )
            }

            Section {
                Picker("Authority Hosting", selection: .constant(false)) {
                    Text("Off — Join Networks Only").tag(false)
                    Text("On — Host on This iPhone (Coming Later)").tag(true)
                }
                .disabled(true)
                .accessibilityValue("Off, join networks only")
            } header: {
                Text("Advanced")
            } footer: {
                Text("iPhone authority hosting is planned but not available yet. This iPhone can currently join or repair access to an existing Beakr'Net.")
            }
        }
        .navigationTitle("This Device")
    }
}

private final class WiFiPathObserver: @unchecked Sendable {
    var updates: AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let queue = DispatchQueue(label: "net.beakr.wifi-path-monitor")
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}
#endif

private struct IncomingMessagesSection: View {
    let messages: [IncomingMessage]
    let recipientName: (UUID) -> String
    let hasHistory: Bool
    let requestHistoryDeletion: () -> Void

    var body: some View {
        Section {
            if messages.isEmpty {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "tray",
                    description: Text("Messages received by this device will appear here.")
                )
            } else {
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.body)
                        if let source = message.source {
                            Text("From \(recipientName(source))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(message.receivedAt, format: .dateTime.hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Delete Message History", systemImage: "trash", role: .destructive, action: requestHistoryDeletion)
                .disabled(!hasHistory)
        } header: {
            Text("Inbox")
        } footer: {
            Text("Deletes received, delivered, and failed message history. Queued messages are preserved.")
        }
    }
}

private struct JoinAnotherNetworkSection: View {
    let join: () -> Void

    var body: some View {
        Section {
            Button("Join Another Network", systemImage: "network.badge.plus", action: join)
        }
    }
}

private struct NetworkOverviewSection: View {
    let networks: [NetworkSummary]
    let activeNetworkName: String?
    let authorityHostname: String?
    let role: String
    let switchNetwork: (NetworkProfileID) -> Void

    var body: some View {
        Section("Network") {
            if networks.isEmpty {
                Text("No network selected")
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Network",
                    selection: Binding(
                        get: { networks.first(where: \.isActive)?.id },
                        set: { newValue in
                            if let newValue { switchNetwork(newValue) }
                        }
                    )
                ) {
                    ForEach(networks) { network in
                        Text(network.displayName).tag(network.id as NetworkProfileID?)
                    }
                }
                .labelsHidden()

                if role == "Network Authority and Creator",
                   let activeNetworkName,
                   let authorityHostname {
                    LabeledContent("Authority") {
                        Text("\(activeNetworkName) (Authority Host: \(authorityHostname))")
                    }
                }

                LabeledContent("Role", value: role)

            }
        }
    }
}

private struct DeviceOverviewSection: View {
    let displayName: String
    let nodeID: UUID?
    let state: NodeBootstrapState
    let statusMessage: String

    var body: some View {
        Section("This Device") {
            LabeledContent("Name", value: displayName)

            if let nodeID {
                LabeledContent("Node Address") {
                    Text(nodeID.uuidString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Label(statusMessage, systemImage: state.systemImage)
                .foregroundStyle(state == .failed ? .red : .secondary)
        }
    }
}

#if os(macOS)
private struct DeviceDetailsSection: View {
    @Binding var friendlyName: String
    let nodeID: UUID?
    let state: NodeBootstrapState
    let statusMessage: String
    let applyFriendlyName: () -> Void

    var body: some View {
        Section {
            TextField("Friendly Name", text: $friendlyName)
                .accessibilityLabel("Device Friendly Name")
                .onSubmit(applyFriendlyName)

            Button("Apply Friendly Name", systemImage: "checkmark") {
                applyFriendlyName()
            }
            .disabled(friendlyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            LabeledContent("Device ID") {
                if let nodeID {
                    Text(nodeID.uuidString)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Created after joining or creating a network")
                        .foregroundStyle(.secondary)
                }
            }

            Label(statusMessage, systemImage: state.systemImage)
                .foregroundStyle(state == .failed ? .red : .secondary)
        } header: {
            Text("This Device")
        } footer: {
            Text("The friendly name is stored on this Mac. The device ID uniquely identifies this device on the active Beakr network.")
        }
    }
}
#endif

private extension NodeBootstrapState {
    var systemImage: String {
        switch self {
        case .starting:
            "key.horizontal"
        case .needsConfiguration:
            "gear.badge"
        case .creatingNetwork:
            "network.badge.shield.half.filled"
        case .joiningNetwork:
            "person.badge.key.fill"
        case .identityReady:
            "checkmark.shield"
        case .enrolling:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready:
            "checkmark.shield.fill"
        case .failed:
            "exclamationmark.shield"
        }
    }
}

private struct InviteDeviceSection: View {
    let invitation: String
    let create: () -> Void

    var body: some View {
        Section {
            if invitation.isEmpty {
                Button("Generate QR Code", systemImage: "qrcode", action: create)
            } else {
                Button("Re-Generate QR Code", systemImage: "arrow.clockwise", action: create)
            }

            if !invitation.isEmpty {
                InvitationQRCodeView(invitation: invitation)
                    .frame(width: 320)
                    .frame(minHeight: 390)

                InvitationShareLink(invitation: invitation) {
                    Label("Share Invitation", systemImage: "square.and.arrow.up")
                }

                Text(invitation)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Device Invitation JSON")
            }
        } header: {
            Text("Network Invitation")
        } footer: {
            Text("The invitation expires after 10 minutes and can be used once. It contains public trust material only.")
        }
    }
}

private struct NetworkAddressesContent: View {
    let localName: String
    let localID: UUID?
    let members: [NetworkMemberSummary]
    let onlineMemberIDs: Set<UUID>
    let isLocalDeviceOnline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NetworkAddressRow(
                displayName: localName,
                deviceID: localID,
                detail: "This Device",
                isOnline: isLocalDeviceOnline
            )

            ForEach(members) { member in
                NetworkAddressRow(
                    displayName: member.displayName,
                    deviceID: member.id,
                    detail: nil,
                    isOnline: onlineMemberIDs.contains(member.id)
                )
            }

            if members.isEmpty {
                Text("No other addressable devices have been discovered on the active network.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NetworkAddressRow: View {
    let displayName: String
    let deviceID: UUID?
    let detail: LocalizedStringResource?
    let isOnline: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isOnline ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .accessibilityLabel(isOnline ? "Online" : "Offline")

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let deviceID {
                    Text(deviceID.uuidString)
                        .font(.caption.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Address is created during network setup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DeviceOperationStatusSection: View {
    let state: NodeBootstrapState
    let statusMessage: String

    var body: some View {
        Section("Status") {
            Label(statusMessage, systemImage: state.systemImage)
                .foregroundStyle(state == .failed || state == .needsConfiguration ? .red : .secondary)
        }
    }
}

private struct TrustRecoverySection: View {
    let isWorking: Bool
    let enroll: () -> Void

    var body: some View {
        Section("Device Setup") {
            Button("Retry Device Setup", systemImage: "arrow.clockwise", action: enroll)
                .disabled(isWorking)
            if isWorking {
                ProgressView("Securing this device")
            }
        }
    }
}

private struct DevelopmentAuthoritySection: View {
    @Binding var controlPlaneURL: String
    @Binding var networkIDText: String
    @Binding var authorityPublicKeyBase64: String
    @Binding var authorityCertificateBase64: String
    @Binding var credentialJSON: String
    let save: () -> Void

    var body: some View {
        Section {
            TextField("HTTPS Control-Plane URL", text: $controlPlaneURL)
                .disableTextAutocapitalization()
                .autocorrectionDisabled()
                .accessibilityLabel("HTTPS Control-Plane URL")

            TextField("Network ID", text: $networkIDText)
                .disableTextAutocapitalization()
                .autocorrectionDisabled()
                .accessibilityLabel("Network ID")

            TextField("Authority Public Key (Base64)", text: $authorityPublicKeyBase64)
                .disableTextAutocapitalization()
                .autocorrectionDisabled()
                .accessibilityLabel("Authority Public Key")

            TextField("Authority CA Certificate DER (Base64)", text: $authorityCertificateBase64)
                .disableTextAutocapitalization()
                .autocorrectionDisabled()
                .accessibilityLabel("Authority CA Certificate")

            SecureField("Authority-Issued Credential JSON", text: $credentialJSON)
                .disableTextAutocapitalization()
                .autocorrectionDisabled()
                .accessibilityLabel("Authority-Issued Credential JSON")

            Button("Verify and Save", systemImage: "checkmark.shield", action: save)
        } header: {
            Text("Development Authority")
        } footer: {
            Text("Development configuration only. The credential is stored in Keychain; private identity keys never leave Keychain storage.")
        }
    }
}

private struct MessageComposerSection: View {
    let recipients: [MessageRecipient]
    let onlineRecipientIDs: Set<UUID>
    @Binding var destinationID: UUID?
    @Binding var messageText: String
    let canSend: Bool
    let send: () -> Void

    var body: some View {
        Section("Message Editor") {
            LabeledContent("To") {
                Menu {
                    Button("Choose a recipient") {
                        destinationID = nil
                    }

                    Divider()

                    ForEach(recipients) { recipient in
                        let isOnline = onlineRecipientIDs.contains(recipient.id)
                        Button {
                            destinationID = recipient.id
                        } label: {
                            Label(
                                "\(recipient.name) — \(isOnline ? "Online" : "Offline")",
                                systemImage: destinationID == recipient.id ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    if let selectedRecipient {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(selectedRecipientIsOnline ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(selectedRecipient.name)
                        }
                    } else {
                        Text("Choose a recipient")
                    }
                }
                .accessibilityLabel("Recipient Address")
                .accessibilityValue(selectedRecipientAccessibilityValue)
            }

            if recipients.isEmpty {
                Text("No other recipient addresses are currently available on the active network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            TextField("Message", text: $messageText, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityLabel("Message")

            Button("Send", systemImage: "paperplane", action: send)
                .disabled(!canSend)

            if destinationID != nil {
                Text(
                    selectedRecipientIsOnline
                        ? "Recipient is online — Beakr will attempt delivery now."
                        : "Recipient is offline — Send will hold the message until the device reconnects."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedRecipientIsOnline: Bool {
        destinationID.map(onlineRecipientIDs.contains) ?? false
    }

    private var selectedRecipient: MessageRecipient? {
        guard let destinationID else { return nil }
        return recipients.first { $0.id == destinationID }
    }

    private var selectedRecipientAccessibilityValue: String {
        guard let selectedRecipient else { return "No recipient selected" }
        return "\(selectedRecipient.name), \(selectedRecipientIsOnline ? "online" : "offline")"
    }
}

private struct OutgoingMessagesSection: View {
    let messages: [OutgoingMessage]
    let recipientName: (UUID) -> String
    let statusMessage: String
    let requestQueuedDeletion: () -> Void

    var body: some View {
        Section {
            if messages.isEmpty {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "tray",
                    description: Text("Messages queued on this device will appear here.")
                )
            } else {
                ForEach(messages) { message in
                    OutgoingMessageRow(
                        messageBody: message.body,
                        destinationName: recipientName(message.destination),
                        destinationAddress: message.destination,
                        state: message.state
                    )
                }
            }

            Button("Delete Queued Messages", systemImage: "xmark.circle", role: .destructive, action: requestQueuedDeletion)
                .disabled(!messages.contains { $0.state == .queued || $0.state == .sending })
        } header: {
            Text("Outbox")
        } footer: {
            Label(statusMessage, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
    }
}

private struct OutgoingMessageRow: View {
    let messageBody: String
    let destinationName: String
    let destinationAddress: UUID
    let state: MessageDeliveryState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(messageBody)
                .lineLimit(3)

            Text("To \(destinationName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(destinationAddress.uuidString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Label(state.title, systemImage: state.systemImage)
                .font(.caption)
                .foregroundStyle(state.color)
        }
    }
}

private struct RecipientManagementSection: View {
    let recipients: [MessageRecipient]
    let add: (String, String) -> Bool
    let rename: (UUID, String) -> Void
    let remove: (UUID) -> Void

    @State private var newName = ""
    @State private var newAddress = ""

    var body: some View {
        Section {
            if recipients.isEmpty {
                Text("No saved recipients")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recipients) { recipient in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(
                                "Friendly Name",
                                text: Binding(
                                    get: { recipient.name },
                                    set: { rename(recipient.id, $0) }
                                )
                            )
                            Text(recipient.address.uuidString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Remove \(recipient.name)", systemImage: "trash", role: .destructive) {
                            remove(recipient.id)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }

            TextField("Friendly Name", text: $newName)
            TextField("Recipient Address", text: $newAddress)
                .disableTextAutocapitalization()
                .autocorrectionDisabled()

            Button("Add Recipient", systemImage: "person.badge.plus") {
                if add(newName, newAddress) {
                    newName = ""
                    newAddress = ""
                }
            }
            .disabled(
                newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("Contacts Management")
        } footer: {
            Text("Friendly names are stored on this device. Removing a recipient hides it from the To menu without removing that device from the network.")
        }
    }
}


private extension MessageDeliveryState {
    var detailTitle: String {
        switch self {
        case .sending: "Queueing"
        case .queued: "Queued"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .failed: "Not Queued"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .sending:
            "Queueing"
        case .queued:
            "Queued"
        case .sent:
            "Sent"
        case .delivered:
            "Delivered"
        case .failed:
            "Not Queued"
        }
    }

    var systemImage: String {
        switch self {
        case .sending:
            "clock"
        case .queued:
            "checkmark.circle"
        case .sent:
            "paperplane.fill"
        case .delivered:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .sending:
            .secondary
        case .queued:
            .green
        case .sent:
            .blue
        case .delivered:
            .green
        case .failed:
            .orange
        }
    }
}

private extension View {
    @ViewBuilder
    func disableTextAutocapitalization() -> some View {
#if os(iOS)
        textInputAutocapitalization(.never)
#else
        self
#endif
    }
}

#Preview {
    ContentView()
}
