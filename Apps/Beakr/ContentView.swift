import SwiftUI
import UniformTypeIdentifiers
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetHost
#if os(macOS)
import AppKit
import Darwin
import Network
#elseif os(iOS)
import AudioToolbox
import Darwin
import Network
import NetworkExtension
import UIKit
#endif

private struct UsedInvitationNotice: View {
    var body: some View {
        ContentUnavailableView(
            "Invitation No Longer Available",
            systemImage: "checkmark.shield",
            description: Text("This invitation has already been used or closed. Generate a new invitation for another device.")
        )
    }
}

private extension MessageFlagColor {
    static let appleMailMenuOrder: [MessageFlagColor] = [
        .orange,
        .red,
        .purple,
        .blue,
        .yellow,
        .green,
        .gray
    ]

    var title: LocalizedStringResource {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Grey"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

#if os(macOS)
    var macFlagImage: NSImage {
        guard let symbol = NSImage(
            systemSymbolName: "flag.fill",
            accessibilityDescription: String(localized: title)
        ) else {
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [macColor])
        let image = symbol.withSymbolConfiguration(configuration) ?? symbol
        image.isTemplate = false
        return image
    }

    private var macColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
#endif
}

private struct NetworkInformationRow<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)

            Spacer(minLength: 12)

            content
                .multilineTextAlignment(.trailing)
        }
    }
}

private enum NetworkSectionInformation: Identifiable, Hashable {
    case parameters
    case devices

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .parameters: "Network Parameters"
        case .devices: "Devices"
        }
    }
}

private struct NetworkSectionInformationButton: View {
    let information: NetworkSectionInformation
    let show: (NetworkSectionInformation) -> Void

    var body: some View {
        Button {
            show(information)
        } label: {
            Image(systemName: "info.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("About \(information.title)")
    }
}

private struct NetworkSectionInformationView: View {
    let information: NetworkSectionInformation
#if os(macOS)
    @Environment(\.dismiss) private var dismiss
#endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "info.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)

                    switch information {
                    case .parameters:
                        informationRow("Network Name", description: "The name used to identify this network. The name can change; the Network ID does not.")
                        informationRow("Network ID", description: "The permanent unique identity of the network.")
                        informationRow("Authority", description: "The device responsible for trust and membership, including approvals, credentials, and revocation.")
                        informationRow("Services", description: "The application features available on the network. Messaging is the available service in Release 1.")
                        informationRow("Status", description: "Whether this is the active network. Expand Status to see connection and device availability details.")
                    case .devices:
                        informationRow("Role", description: "The permissions each device has on this network. The Network Authority is shown first; other devices are managers or members.")
                        informationRow("Online", description: "The device is currently reachable on the active network.", color: .green)
                        informationRow("Offline", description: "The device is a known network member but is not currently reachable. Messages can remain queued until it reconnects.", color: .secondary)
                        informationRow("Cached", description: "Authenticated device information, such as its name and last-seen time, is remembered locally while it is offline. Cached information is not a live connection.", color: .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle(Text(information.title))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
#if os(macOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
#endif
        }
#if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
#else
        .frame(width: 500, height: information == .parameters ? 530 : 390)
#endif
    }

    private func informationRow(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        color: Color = .accentColor
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MessagingServicesView: View {
    let bootstrap: NodeBootstrapModel
    @State private var isSwitchingMessaging = false
    @State private var messagingFeedback: String?

    var body: some View {
        Form {
            Section("Messaging") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose the network this device uses for messaging. Authority hosting is managed separately under Networks.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(bootstrap.networks) { network in
                        HStack {
                            Text(network.displayName)
                            Spacer()
                            if network.isActive {
                                Label("Selected for Messaging", systemImage: "bubble.left.fill")
                                    .foregroundStyle(.blue)
                            } else {
                                Button("Use for Messaging") {
                                    isSwitchingMessaging = true
                                    Task {
                                        await bootstrap.switchNetwork(to: network.id)
                                        messagingFeedback = bootstrap.statusMessage
                                        isSwitchingMessaging = false
                                    }
                                }
                                .disabled(isSwitchingMessaging || bootstrap.authorityHostingBusy)
                            }
                        }
                    }
                    if isSwitchingMessaging {
                        ProgressView("Switching messaging network…")
                    }
                    if let messagingFeedback {
                        Text(messagingFeedback).font(.caption).foregroundStyle(.secondary)
                    }
                    if let network = bootstrap.networks.first(where: \.isActive) {
                        Divider()
                        MessagingConnectivityDisclosure(
                            isActive: true,
                            requiresAttention: bootstrap.state != .ready,
                            connectivity: bootstrap.activeNetworkConnectivity,
                            knownDeviceCount: bootstrap.members(for: network).count,
                            onlineDeviceCount: bootstrap.onlineMemberIDs.count,
                            credentialStatus: network.credentialStatus
                        )
                        MessagingHealthDetailsView(bootstrap: bootstrap)
                    } else if !bootstrap.networks.isEmpty {
                        Divider()
                        Text("Messaging Status").font(.headline)
                        Label("Off — No network selected for messaging", systemImage: "bubble.left")
                            .foregroundStyle(.secondary)
                        Text("Choose Use for Messaging above to enable messaging. Network Authority services continue independently.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if bootstrap.networks.isEmpty {
                        Text("Create or join a network in Networks first.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Services")
    }
}

private struct MessagingHealthDetailsView: View {
    let bootstrap: NodeBootstrapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Messaging Status").font(.headline)
            Text(bootstrap.activeNetworkStatusTitle)
            Label(bootstrap.messagingHealthMessage,
                  systemImage: bootstrap.messagingHealth == .degraded || bootstrap.messagingHealth == .blocked
                    ? "exclamationmark.triangle.fill" : "bubble.left.fill")
                .foregroundStyle(bootstrap.messagingHealth.color)
                .fixedSize(horizontal: false, vertical: true)
            if bootstrap.peerTLSFailureCount > 0 {
                Text("A discovered device’s certificate could not be validated. Check that both devices use the same network authority, then refresh network credentials. The warning clears when that endpoint passes validation; other peer connections do not clear it.")
                    .font(.callout)
            }
            if bootstrap.credentialStatus != nil {
                Text(bootstrap.statusMessage)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if bootstrap.credentialStatus != nil || bootstrap.peerTLSFailureCount > 0 {
                Text("Open Network → Network Credentials to review or refresh this network’s credentials.")
                    .font(.callout)
            }
        }
    }
}

private struct NetworkCredentialDetailsView: View {
    let bootstrap: NodeBootstrapModel
    let network: NetworkSummary

    @State private var savedDetails: NetworkCredentialDetails?
    @State private var savedAuthority: String?

    private var displayedDetails: NetworkCredentialDetails {
        network.isActive ? bootstrap.credentialDetails : (savedDetails ?? NetworkCredentialDetails())
    }

    private var displayedAuthority: String? {
        if network.isHostingAuthority { return bootstrap.deviceDisplayName }
        return network.isActive
            ? (bootstrap.activeAuthorityDeviceName ?? bootstrap.activeAuthorityEndpoint)
            : savedAuthority
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network Credentials").font(.headline)
            activeCredentials
        }
        .task(id: network.id) {
            savedDetails = nil
            savedAuthority = nil
            let snapshot = await bootstrap.savedCredentialDetails(for: network.id)
            guard !Task.isCancelled else { return }
            savedDetails = snapshot?.details
            savedAuthority = snapshot?.authority
        }
    }

    private var activeCredentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            if network.isActive && bootstrap.credentialStatus != nil {
                Text(bootstrap.statusMessage)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 0) {
                    credentialRow("Credential", value: Text("Value"), remaining: Text("Relative Time"))
                        .fontWeight(.semibold)
                        .background(.primary.opacity(0.06))
                    if let authority = displayedAuthority {
                        Divider()
                        credentialRow("Authority", explanation: "The device that manages membership and issues trusted credentials for this network.", value: Text(authority))
                    }
                    if let expiry = displayedDetails.accessExpiresAt {
                        Divider()
                        credentialRow("Device Access Expires", explanation: "When this device’s permission to belong to the network expires. Refreshing records does not grant new permissions.", value: Text(expiry, format: .dateTime.year().month().day().hour().minute()), remaining: Text(compactTime(to: expiry, from: context.date)))
                    } else {
                        Divider()
                        credentialRow("Device Access Expires", value: Text("Not available"))
                    }
                    if let expiry = displayedDetails.certificateExpiresAt {
                        Divider()
                        credentialRow("Device Certificate Expires", explanation: "When this device’s certificate for secure connections expires. A valid certificate is required to authenticate this device to other devices.", value: Text(expiry, format: .dateTime.year().month().day().hour().minute()), remaining: Text(compactTime(to: expiry, from: context.date)))
                    } else {
                        Divider()
                        credentialRow("Device Certificate Expires", value: Text("Not available"))
                    }
                    if let updated = displayedDetails.revocationsUpdatedAt {
                        Divider()
                        credentialRow("Revocation Records Updated", explanation: "When the authority generated the saved signed record of revoked credentials. The time column shows how long ago this was.", value: Text(updated, format: .dateTime.year().month().day().hour().minute()), remaining: Text(compactTime(to: updated, from: context.date, isUpdate: true)))
                    } else {
                        Divider()
                        credentialRow("Revocation Records Updated", value: Text("Not available"))
                    }
                    if let expiry = displayedDetails.revocationsValidUntil {
                        Divider()
                        credentialRow("Validation Refresh Due", explanation: "When the saved revocation records become too old for trust validation. Refresh retrieves current signed records from the authority.", value: Text(expiry, format: .dateTime.year().month().day().hour().minute()), remaining: Text(compactTime(to: expiry, from: context.date)))
                    } else {
                        Divider()
                        credentialRow("Validation Refresh Due", value: Text("Not available"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .textSelection(.enabled)
                .padding(.top, 8)
            }
            Button(bootstrap.isRefreshingCredentials ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
                Task { await bootstrap.refreshNetworkCredentials() }
            }
            .disabled(!network.isActive || bootstrap.isRefreshingCredentials || bootstrap.state == .securing || bootstrap.state == .starting)
            if !network.isActive {
                Text("Saved credentials are shown. Certificate and validation records may be unavailable until this device is prepared for network use. Refresh currently requires selecting this network for messaging in Services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Refresh Network Credentials checks this device’s network access and updates signed membership and revocation records. It does not grant new permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func credentialRow(_ title: LocalizedStringResource, explanation: LocalizedStringResource? = nil, value: Text, remaining: Text = Text("—")) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Text(title)
                if let explanation {
                    CredentialInformationButton(title: title, explanation: explanation)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.separator).frame(width: 1)
                }
            value
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.separator).frame(width: 1)
                }
            remaining
                .monospacedDigit()
                .frame(width: 80, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func compactTime(to date: Date, from now: Date, isUpdate: Bool = false) -> String {
        let seconds = date.timeIntervalSince(now)
        let minutes = Int(abs(seconds) / 60)
        let duration: String
        if minutes >= 1_440 {
            duration = "\(minutes / 1_440)d \((minutes % 1_440) / 60)h"
        } else if minutes >= 60 {
            duration = "\(minutes / 60)h \(minutes % 60)m"
        } else if minutes > 0 {
            duration = "\(minutes)m"
        } else {
            duration = "<1m"
        }
        if isUpdate {
            return seconds <= 0 ? "\(duration) ago" : "in \(duration)"
        }
        return seconds > 0 ? duration : "\(duration) overdue"
    }

}

private struct CredentialInformationButton: View {
    let title: LocalizedStringResource
    let explanation: LocalizedStringResource
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("About \(String(localized: title))"))
        .help(Text(explanation))
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(explanation).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { isPresented = false }
            }
            .padding()
            .frame(idealWidth: 300, maxWidth: 340)
        }
    }
}

private struct NetworkLastErrorDisclosure: View {
    let message: String?
    @State private var isExpanded = false

    @ViewBuilder
    var body: some View {
        if let message, !message.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label("Last Error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

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
    @AppStorage("net.beakr.settings.networkRequest") private var networkSettingsRequest = ""
    @AppStorage("net.beakr.networkManager.selectedNetworkID") private var persistedNetworkSettingsID = ""
    @State private var selectedSidebarRoute: MacSidebarRoute?
    @State private var selectedSidebarCategory = MacSidebarCategory.mailboxes
    @State private var selectedDetailRoute: MacDetailRoute?
    @State private var rememberedMailboxSelections: [MailboxSelection: MacDetailRoute] = [:]
    @State private var showingContactsDialog = false
    @State private var showingComposerDialog = false
    @State private var contextPendingDeletion: ContextSummary?
    @State private var devicePendingRemoval: MacMemberDetail?
    @State private var confirmingHistoryDeletion = false
    @State private var confirmingQueuedDeletion = false
    @State private var macMessageSearchText = ""
    @State private var restoreMacContentFocusOnActivation = false
    @State private var macColumnVisibility = NavigationSplitViewVisibility.all
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
                    await bootstrap.reconcileLocalNetworkMembers()
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
                if phase == .inactive {
                    bootstrap.applicationDidBecomeInactive()
                } else if phase == .background {
                    Task { await bootstrap.applicationDidEnterBackground() }
                } else if phase == .active {
                    Task { await bootstrap.applicationBecameActive() }
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
        NavigationSplitView(columnVisibility: $macColumnVisibility) {
            mailboxSidebar
                .background(MacSecondaryWindowPlacement(role: .sidebar))
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
                    if case .message = selectedDetailRoute {
                        MessageBodyToolbar(
                            reply: replyToSelectedMessage,
                            replyAll: replyToSelectedMessage,
                            forward: forwardSelectedMessage,
                            delete: deleteSelectedMessage,
                            setFlag: setFlagOnSelectedMessage,
                            canReply: canReplyToSelectedMessage,
                            canForward: canForwardSelectedMessage,
                            canDelete: canModifySelectedMessage,
                            canFlag: canModifySelectedMessage,
                            flagColor: selectedMessageFlagColor
                        )
                    } else if case .device = selectedDetailRoute {
                        DevicePropertiesToolbar(
                            removeDevice: { devicePendingRemoval = selectedDevice },
                            canRemoveDevice: selectedDevice.map { device in
                                !device.isLocalDevice
                                    && device.isActiveNetwork
                                    && bootstrap.networks.first(where: { $0.id == device.networkID })?.isHostingAuthority == true
                            } ?? false
                        )
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .defaultFocus($focusedMacColumn, .content)
        .frame(minWidth: 800, minHeight: 170)
        .sheet(isPresented: $showingContactsDialog) {
            contactsDialog
        }
        .sheet(isPresented: $showingComposerDialog, onDismiss: model.discardDraft) {
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
            "Remove Device from Network?",
            isPresented: Binding(
                get: { devicePendingRemoval != nil },
                set: { if !$0 { devicePendingRemoval = nil } }
            ),
            presenting: devicePendingRemoval
        ) { device in
            Button("Remove \(device.displayName)", role: .destructive) {
                devicePendingRemoval = nil
                selectedDetailRoute = nil
                Task { await bootstrap.removeNetworkMember(device.deviceID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("This revokes \(device.displayName)’s current credential and disconnects it from the network. The device will need a new invitation to join again. Local message history is preserved.")
        }
        .task { await bootstrap.start() }
        .task { await model.observeIncomingMessages() }
        .task { await model.observeDeliveryUpdates() }
        .task { await model.observeReadReceipts() }
        .task { await model.observeMailboxPersistenceFailures() }
        .task(id: bootstrap.state) {
            guard bootstrap.state == .ready else { return }
            while !Task.isCancelled {
                await bootstrap.reconcileLocalNetworkMembers()
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
            guard selectedSidebarRoute == nil,
                  let activeNetwork = networks.first(where: \.isActive) else { return }
            selectedSidebarRoute = .network(activeNetwork.id)
        }
        .onChange(of: selectedSidebarRoute) { previousRoute, route in
            if let networkID = route?.networkID {
                persistedNetworkSettingsID = networkID.rawValue.uuidString
            }
            if let previousMailbox = previousRoute?.mailboxSelection,
               selectedDetailRoute?.messageSelection != nil {
                rememberedMailboxSelections[previousMailbox] = selectedDetailRoute
            }

            if let mailbox = route?.mailboxSelection,
               let rememberedRoute = rememberedMailboxSelections[mailbox],
               isMessageVisible(rememberedRoute, in: mailbox) {
                selectedDetailRoute = rememberedRoute
            } else {
                if let mailbox = route?.mailboxSelection {
                    rememberedMailboxSelections[mailbox] = nil
                }
                selectedDetailRoute = nil
            }
            if case .network? = route {
                selectedSettingsTab = BeakrSettingsTab.networks.rawValue
                focusedMacColumn = nil
                return
            }
            Task { @MainActor in
                await Task.yield()
                focusedMacColumn = .content
            }
        }
        .onChange(of: selectedDetailRoute) { _, route in
            if let mailbox = selectedMailbox {
                if let route, route.messageSelection != nil, isMessageVisible(route, in: mailbox) {
                    rememberedMailboxSelections[mailbox] = route
                } else if route == nil {
                    rememberedMailboxSelections[mailbox] = nil
                }
            }
            guard route != nil else { return }
            Task { @MainActor in
                await Task.yield()
                focusedMacColumn = .content
            }
        }
        .onChange(of: selectedIncomingMessages.map(\.id)) { _, _ in
            validateSelectedMessage()
        }
        .onChange(of: selectedOutgoingMessages.map(\.id)) { _, _ in
            validateSelectedMessage()
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
        var orderedNetworks = bootstrap.networks
        if let activeIndex = orderedNetworks.firstIndex(where: \.isActive) {
            let activeNetwork = orderedNetworks.remove(at: activeIndex)
            orderedNetworks.insert(activeNetwork, at: 0)
        }
        if let createdID = bootstrap.lastCreatedNetworkID,
           let createdIndex = orderedNetworks.firstIndex(where: { $0.id == createdID }) {
            let createdNetwork = orderedNetworks.remove(at: createdIndex)
            orderedNetworks.insert(createdNetwork, at: 0)
        }
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
            selectedCategory: $selectedSidebarCategory,
            requestContextDeletion: { contextPendingDeletion = $0 },
            showNetworkDetails: { network in openMacNetworkSettings(network) },
            openNetworkSettings: openMacNetworkSettings
        )
    }

    private func openMacNetworkSettings(_ network: NetworkSummary?) {
        if let networkID = network?.id ?? selectedSidebarRoute?.networkID {
            persistedNetworkSettingsID = networkID.rawValue.uuidString
        }
        selectedSettingsTab = BeakrSettingsTab.networks.rawValue
        networkSettingsRequest = UUID().uuidString
        openSettings()
    }

    private func refreshMacNetworks() async {
        await bootstrap.refreshNetworkCredentials()
    }

    private var messageList: some View {
        MacContextList(
            bootstrap: bootstrap,
            sidebarRoute: selectedSidebarRoute,
            networks: bootstrap.networks,
            selectedCategory: selectedSidebarCategory,
            detailRoute: $selectedDetailRoute,
            incomingMessages: selectedIncomingMessages,
            outgoingMessages: selectedOutgoingMessages,
            memberDirectory: macMemberDirectory,
            focus: $focusedMacColumn,
            canRemoveDevice: { device in
                !device.isLocalDevice
                    && device.isActiveNetwork
                    && bootstrap.networks.first(where: { $0.id == device.networkID })?.isHostingAuthority == true
            },
            requestDeviceRemoval: { devicePendingRemoval = $0 },
            displayName: selectedDisplayName,
            isRead: selectedIsRead,
            setRead: { isRead, id in
                guard selectedMailbox?.contextID == nil else { return }
                model.setRead(isRead, messageID: id)
            },
            isFlagged: selectedIsFlagged,
            flagColor: selectedFlagColor,
            setFlag: { color, id in
                guard selectedMailbox?.contextID == nil else { return }
                model.setFlag(color, messageID: id)
            },
            reply: replyToMessage,
            replyAll: replyToMessage,
            canReply: canReplyToMessage,
            forward: forwardMessage,
            canForward: selectedNetworkIsActive,
            moveIncomingToTrash: { id in
                guard selectedMailbox?.contextID == nil else { return }
                Task { await model.deleteIncomingMessage(id: id) }
            },
            moveOutgoingToTrash: { id in
                guard selectedMailbox?.contextID == nil else { return }
                Task { await model.deleteOutgoingMessage(id: id) }
            },
            restoreMessage: { id in
                guard selectedMailbox?.contextID == nil else { return }
                model.restoreMessage(id: id)
            },
            permanentlyDeleteIncoming: { id in
                guard selectedMailbox?.contextID == nil else { return }
                Task { await model.permanentlyDeleteIncomingMessage(id: id) }
            },
            permanentlyDeleteOutgoing: { id in
                guard selectedMailbox?.contextID == nil else { return }
                model.permanentlyDeleteOutgoingMessage(id: id)
            }
        )
    }

    @ViewBuilder
    private var messageDetail: some View {
        if case .network(let id) = selectedSidebarRoute {
            BeakrSettingsView(bootstrap: bootstrap, embeddedNetworkID: id)
                .id(id)
                .navigationSplitViewColumnWidth(min: 420, ideal: 540, max: 800)
        } else {
            MacDetailContent(
                bootstrap: bootstrap,
                route: selectedDetailRoute,
                incomingMessages: selectedIncomingMessages,
                outgoingMessages: selectedOutgoingMessages,
                memberDirectory: macMemberDirectory,
                messageSearchText: $macMessageSearchText,
                displayName: selectedDisplayName,
                shouldMarkIncomingAsRead: selectedNetworkIsActive,
                openIncomingMessage: model.openIncomingMessage
            )
        }
    }

    private var canReplyToSelectedMessage: Bool {
        guard case .incoming(let id) = selectedMessage else { return false }
        return canReplyToMessage(id)
    }

    private func canReplyToMessage(_ id: UUID) -> Bool {
        guard selectedNetworkIsActive,
              let source = selectedIncomingMessages.first(where: { $0.id == id })?.source else {
            return false
        }
        return model.isAddressable(source)
    }

    private var canForwardSelectedMessage: Bool {
        guard selectedNetworkIsActive, let selectedMessage else { return false }
        switch selectedMessage {
        case .incoming(let id):
            return selectedIncomingMessages.contains(where: { $0.id == id })
        case .outgoing(let id):
            return selectedOutgoingMessages.contains(where: { $0.id == id })
        }
    }

    private var canModifySelectedMessage: Bool {
        selectedNetworkIsActive && selectedMessage != nil
    }

    private func isMessageVisible(_ route: MacDetailRoute, in mailbox: MailboxSelection) -> Bool {
        guard selectedMailbox == mailbox, let selection = route.messageSelection else { return false }
        switch selection {
        case .incoming(let id):
            return selectedIncomingMessages.contains(where: { $0.id == id })
        case .outgoing(let id):
            return selectedOutgoingMessages.contains(where: { $0.id == id })
        }
    }

    private func validateSelectedMessage() {
        guard let mailbox = selectedMailbox,
              let route = selectedDetailRoute,
              route.messageSelection != nil,
              !isMessageVisible(route, in: mailbox) else { return }
        rememberedMailboxSelections[mailbox] = nil
        selectedDetailRoute = nil
    }

    private var selectedMessageFlagColor: MessageFlagColor? {
        guard let selectedMessage else { return nil }
        switch selectedMessage {
        case .incoming(let id), .outgoing(let id):
            return model.flagColor(for: id)
        }
    }

    private func deleteSelectedMessage() {
        guard canModifySelectedMessage, let selectedMessage else { return }
        selectedDetailRoute = nil
        switch (selectedMailbox?.mailbox, selectedMessage) {
        case (.trash, .incoming(let id)):
            Task { await model.permanentlyDeleteIncomingMessage(id: id) }
        case (.trash, .outgoing(let id)):
            model.permanentlyDeleteOutgoingMessage(id: id)
        case (_, .incoming(let id)):
            Task { await model.deleteIncomingMessage(id: id) }
        case (_, .outgoing(let id)):
            Task { await model.deleteOutgoingMessage(id: id) }
        }
    }

    private func setFlagOnSelectedMessage(_ color: MessageFlagColor?) {
        guard canModifySelectedMessage, let selectedMessage else { return }
        switch selectedMessage {
        case .incoming(let id), .outgoing(let id):
            model.setFlag(color, messageID: id)
        }
    }

    private func replyToSelectedMessage() {
        guard case .incoming(let id) = selectedMessage else { return }
        replyToMessage(id)
    }

    private func replyToMessage(_ id: UUID) {
        guard canReplyToMessage(id),
              let message = selectedIncomingMessages.first(where: { $0.id == id }) else { return }
        model.prepareReply(to: message)
        showingComposerDialog = true
    }

    private func forwardSelectedMessage() {
        guard let selectedMessage else { return }
        forwardMessage(selectedMessage)
    }

    private func forwardMessage(_ message: MailMessageSelection) {
        guard selectedNetworkIsActive else { return }
        let body: String?
        switch message {
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
        let messages: [IncomingMessage]
        let trashedIDs: Set<UUID>
        if let contextID = selectedMailbox?.contextID {
            messages = bootstrap.archivedIncomingMessages[contextID] ?? []
            trashedIDs = bootstrap.archivedMailboxMetadata[contextID]?.trashedMessageIDs ?? []
        } else if let networkID = selectedMailbox?.networkID, !selectedNetworkIsActive {
            messages = bootstrap.storedIncomingMessages[networkID] ?? []
            trashedIDs = bootstrap.storedMailboxMetadata[networkID]?.trashedMessageIDs ?? []
        } else {
            messages = model.incomingMessages
            trashedIDs = model.trashedMessageIDs
        }
        return selectedMailbox?.mailbox == .trash
            ? messages.filter { trashedIDs.contains($0.id) }
            : messages.filter { !trashedIDs.contains($0.id) }
    }

    private var selectedOutgoingMessages: [OutgoingMessage] {
        let messages: [OutgoingMessage]
        if let contextID = selectedMailbox?.contextID,
           let metadata = bootstrap.archivedMailboxMetadata[contextID] {
            messages = metadata.outgoingMessages
        } else if let networkID = selectedMailbox?.networkID,
                  !selectedNetworkIsActive,
                  let metadata = bootstrap.storedMailboxMetadata[networkID] {
            messages = metadata.outgoingMessages
        } else {
            messages = model.outgoingMessages
        }
        guard let mailbox = selectedMailbox?.mailbox else { return messages }
        let trashedIDs = selectedMailbox?.contextID.flatMap {
            bootstrap.archivedMailboxMetadata[$0]?.trashedMessageIDs
        } ?? selectedMailbox?.networkID.flatMap {
            selectedNetworkIsActive ? nil : bootstrap.storedMailboxMetadata[$0]?.trashedMessageIDs
        } ?? model.trashedMessageIDs
        if mailbox == .trash {
            return messages.filter { trashedIDs.contains($0.id) }
        }
        return messages.filter { !trashedIDs.contains($0.id) && mailbox.includes($0) }
    }

    private var macMemberDirectory: MacMemberDirectorySnapshot {
        MacMemberDirectorySnapshot(
            networks: bootstrap.networks,
            localDeviceName: bootstrap.deviceDisplayName,
            localDeviceID: bootstrap.nodeID,
            savedMemberships: bootstrap.savedMemberships,
            localNodeIDs: Dictionary(uniqueKeysWithValues: bootstrap.networkSessions.map { ($0.id, $0.profile.localNodeID.rawValue) }),
            localDeviceOnline: bootstrap.state == .ready && bootstrap.activeNetworkConnectivity.isLocalDeviceOnline,
            activeNetworkMembers: bootstrap.networkMembers,
            onlineMemberIDs: bootstrap.onlineMemberIDs
        )
    }

    private func selectedDisplayName(for address: UUID) -> String {
        if let contextID = selectedMailbox?.contextID {
            return bootstrap.archivedMailboxMetadata[contextID]?
                .recipients.first(where: { $0.id == address })?.name ?? address.uuidString
        }
        if let networkID = selectedMailbox?.networkID, !selectedNetworkIsActive {
            return bootstrap.storedMailboxMetadata[networkID]?
                .recipients.first(where: { $0.id == address })?.name ?? address.uuidString
        }
        return model.displayName(for: address)
    }

    private func selectedIsRead(_ messageID: UUID) -> Bool {
        if let contextID = selectedMailbox?.contextID {
            return bootstrap.archivedMailboxMetadata[contextID]?.readMessageIDs.contains(messageID) ?? false
        }
        if let networkID = selectedMailbox?.networkID, !selectedNetworkIsActive {
            return bootstrap.storedMailboxMetadata[networkID]?.readMessageIDs.contains(messageID) ?? false
        }
        return model.isRead(messageID)
    }

    private func selectedIsFlagged(_ messageID: UUID) -> Bool {
        if let contextID = selectedMailbox?.contextID {
            return bootstrap.archivedMailboxMetadata[contextID]?.flaggedMessageIDs.contains(messageID) ?? false
        }
        if let networkID = selectedMailbox?.networkID, !selectedNetworkIsActive {
            return bootstrap.storedMailboxMetadata[networkID]?.flaggedMessageIDs.contains(messageID) ?? false
        }
        return model.isFlagged(messageID)
    }

    private func selectedFlagColor(_ messageID: UUID) -> MessageFlagColor? {
        if let contextID = selectedMailbox?.contextID {
            return bootstrap.archivedMailboxMetadata[contextID]?.messageFlagColors[messageID]
        }
        if let networkID = selectedMailbox?.networkID, !selectedNetworkIsActive {
            return bootstrap.storedMailboxMetadata[networkID]?.messageFlagColors[messageID]
        }
        return model.flagColor(for: messageID)
    }

    private var selectedNetworkIsActive: Bool {
        guard let networkID = selectedMailbox?.networkID else { return false }
        return bootstrap.networks.contains { $0.id == networkID && $0.isActive }
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
                        // Sending clears the reply context, so capture navigation intent first.
                        let preserveMailbox = model.hasReplyContext
                        Task {
                            await model.send()
                            if model.messageText.isEmpty {
                                showingComposerDialog = false
                                if !preserveMailbox,
                                   let activeNetwork = bootstrap.networks.first(where: \.isActive) {
                                    let mailbox = model.outgoingMessages.first.map {
                                        Mailbox.sentItems.includes($0) ? Mailbox.sentItems : Mailbox.outbox
                                    } ?? .outbox
                                    selectedSidebarRoute = .mailbox(
                                        MailboxSelection(networkID: activeNetwork.id, mailbox: mailbox)
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
    @Binding var selectedCategory: MacSidebarCategory
    let requestContextDeletion: (ContextSummary) -> Void
    let showNetworkDetails: (NetworkSummary) -> Void
    let openNetworkSettings: (NetworkSummary?) -> Void
    @State private var showingAddNetwork = false
    @State private var creatingNetwork = true
    @State private var isShowingNetworkStatusInformation = false
    @State private var networkPendingRemoval: NetworkSummary?

    private var selectedNetworkForRemoval: NetworkSummary? {
        guard let id = selection?.networkID else { return nil }
        return orderedNetworks.first { $0.id == id }
    }

    private var activeNetwork: NetworkSummary? {
        orderedNetworks.first(where: \.isActive)
    }

    private var memberDirectory: MacMemberDirectorySnapshot {
        MacMemberDirectorySnapshot(
            networks: orderedNetworks,
            localDeviceName: bootstrap.deviceDisplayName,
            localDeviceID: bootstrap.nodeID,
            savedMemberships: bootstrap.savedMemberships,
            localNodeIDs: Dictionary(uniqueKeysWithValues: bootstrap.networkSessions.map { ($0.id, $0.profile.localNodeID.rawValue) }),
            localDeviceOnline: bootstrap.state == .ready && bootstrap.activeNetworkConnectivity.isLocalDeviceOnline,
            activeNetworkMembers: bootstrap.networkMembers,
            onlineMemberIDs: bootstrap.onlineMemberIDs
        )
    }

    var body: some View {
        List(selection: $selection) {
            Text(
                "Beakr'Net",
                comment: "Product display name shown at the top of the macOS network sidebar."
            )
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

            if bootstrap.state == .failed {
                Text(bootstrap.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("macStartupStatus")
            }

            Section {
                ForEach(orderedNetworks) { network in
                    let counts = mailboxCounts(for: network)
                    MacNetworkOverviewSection(
                        network: network,
                        selection: $selection,
                        selectedCategory: $selectedCategory,
                        incomingCount: counts.incoming,
                        outgoingCount: counts.outgoing,
                        sentCount: counts.sent,
                        trashCount: counts.trash,
                        onlineMemberCount: memberDirectory.members(
                            networkID: network.id,
                            availability: .online
                        ).count,
                        offlineMemberCount: memberDirectory.members(
                            networkID: network.id,
                            availability: .offline
                        ).count,
                        activeConnectivity: bootstrap.activeNetworkConnectivity,
                        authorityHostingState: bootstrap.authorityHostingStates[network.id],
                        authorityHostingEnabled: bootstrap.authorityHostingEnabled.contains(network.id),
                        authorityHostingBusy: bootstrap.authorityHostingBusy,
                        setAuthorityHosting: { enabled in
                            Task { await bootstrap.setAuthorityHosting(enabled, for: network.id) }
                        },
                        membersAreAvailable: network.isActive,
                        showDetails: { showNetworkDetails(network) },
                        makeActive: {
                            guard !network.isActive else { return }
                            Task { await bootstrap.switchNetwork(to: network.id) }
                        },
                        requestRemoval: { networkPendingRemoval = network }
                    )
                }
            } header: {
                MacNetworksSectionHeader(
                    showStatusInformation: { isShowingNetworkStatusInformation = true }
                )
            }

            if !bootstrap.archivedContexts.isEmpty {
                ForEach(bootstrap.archivedContexts) { context in
                    Section {
                        if context.archiveReason == .membershipRevoked {
                            RevokedContextExplanation()
                        }
                        Label("Inbox", systemImage: "tray.and.arrow.down")
                            .font(.caption)
                            .badge(bootstrap.archivedIncomingMessages[context.id]?.filter {
                                !(bootstrap.archivedMailboxMetadata[context.id]?.trashedMessageIDs.contains($0.id) ?? false)
                            }.count ?? 0)
                            .tag(MacSidebarRoute.mailbox(
                                MailboxSelection(contextID: context.id, mailbox: .inbox)
                            ))
                        Label("Outbox", systemImage: "tray.and.arrow.up")
                            .font(.caption)
                            .badge(bootstrap.archivedMailboxMetadata[context.id]?.outgoingMessages
                                .filter {
                                    !(bootstrap.archivedMailboxMetadata[context.id]?.trashedMessageIDs.contains($0.id) ?? false)
                                        && Mailbox.outbox.includes($0)
                                }.count ?? 0)
                            .tag(MacSidebarRoute.mailbox(
                                MailboxSelection(contextID: context.id, mailbox: .outbox)
                            ))
                        Label("Sent Items", systemImage: "paperplane")
                            .font(.caption)
                            .badge(bootstrap.archivedMailboxMetadata[context.id]?.outgoingMessages
                                .filter {
                                    !(bootstrap.archivedMailboxMetadata[context.id]?.trashedMessageIDs.contains($0.id) ?? false)
                                        && Mailbox.sentItems.includes($0)
                                }.count ?? 0)
                            .tag(MacSidebarRoute.mailbox(
                                MailboxSelection(contextID: context.id, mailbox: .sentItems)
                            ))
                        Label("Trash", systemImage: "trash")
                            .font(.caption)
                            .badge(bootstrap.archivedMailboxMetadata[context.id]?.trashedMessageIDs.count ?? 0)
                            .tag(MacSidebarRoute.mailbox(
                                MailboxSelection(contextID: context.id, mailbox: .trash)
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
        .sheet(isPresented: $isShowingNetworkStatusInformation) {
            NetworkStatusInformationView()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Menu {
                        Button("Create Network") {
                            creatingNetwork = true
                            showingAddNetwork = true
                        }
                        Button("Join Network") {
                            creatingNetwork = false
                            showingAddNetwork = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Add Network")
                    .help("Add Network — Create or Join")
                    Button {
                        networkPendingRemoval = selectedNetworkForRemoval
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("removeSelectedNetworkButton")
                    .disabled(selectedNetworkForRemoval == nil)
                    .accessibilityLabel(selectedNetworkForRemoval?.isHostingAuthority == true ? "Delete Selected Network" : "Forget Selected Network")
                    .help(selectedNetworkForRemoval.map {
                        $0.isHostingAuthority ? "Delete \($0.displayName)…" : "Forget \($0.displayName)…"
                    } ?? "Select a network to remove")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        .alert(
            networkPendingRemoval?.isHostingAuthority == true
                ? "Delete Network?"
                : "Forget Network on This Mac?",
            isPresented: Binding(
                get: { networkPendingRemoval != nil },
                set: { if !$0 { networkPendingRemoval = nil } }
            ),
            presenting: networkPendingRemoval
        ) { network in
            if network.isHostingAuthority {
                Button("Delete \(network.displayName)", role: .destructive) {
                    networkPendingRemoval = nil
                    Task { await bootstrap.deleteOwnedNetwork(network.id) }
                }
            } else {
                Button("Forget and Keep Data", role: .destructive) {
                    networkPendingRemoval = nil
                    Task {
                        await bootstrap.forgetJoinedNetwork(
                            network.id,
                            dataDisposition: .keepLocalData
                        )
                    }
                }
                Button("Forget and Delete Data", role: .destructive) {
                    networkPendingRemoval = nil
                    Task {
                        await bootstrap.forgetJoinedNetwork(
                            network.id,
                            dataDisposition: .deleteLocalData
                        )
                    }
                }
            }
            Button("Keep Network", role: .cancel) {}
        } message: { network in
            if network.isHostingAuthority {
                Text("This permanently removes \(network.displayName), its management credentials, and its local data.")
            } else {
                Text(forgetNetworkMessage(
                    for: network,
                    deviceName: "Mac",
                    connectivity: bootstrap.activeNetworkConnectivity
                ))
            }
        }
        .sheet(isPresented: $showingAddNetwork) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showingAddNetwork = false }
                }
                .padding()
                NetworkManagerWindow(bootstrap: bootstrap, creatingNetwork: creatingNetwork) { createdID in
                    selection = .network(createdID)
                    showingAddNetwork = false
                }
            }
            .frame(width: 620, height: 650)
        }
        .listStyle(.sidebar)
        .navigationTitle("Beakr")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openNetworkSettings(activeNetwork)
                } label: {
                    MacNetworkStatusIcon(
                        connectivity: bootstrap.activeNetworkConnectivity,
                        systemImage: "gearshape.fill"
                    )
                    .font(.body)
                }
                .tint(bootstrap.activeNetworkConnectivity.networkTintColor)
                .accessibilityLabel("Network Settings")
                .accessibilityValue(
                    activeNetwork == nil
                        ? (bootstrap.networks.isEmpty ? "No networks configured" : "Messaging off — no network selected")
                        : bootstrap.activeNetworkStatusTitle
                )
                .help(
                    activeNetwork.map {
                        "Open settings for \($0.displayName) — \(bootstrap.activeNetworkStatusTitle)"
                    } ?? (bootstrap.networks.isEmpty
                        ? "Open Network Settings to create or join a network"
                        : "Open Network Settings — messaging is off because no network is selected for messaging")
                )
            }
        }
    }

    private func mailboxCounts(for network: NetworkSummary) -> NetworkMailboxCounts {
        let incomingMessages: [IncomingMessage]
        let outgoingMessages: [OutgoingMessage]
        let trashedMessageIDs: Set<UUID>
        if network.isActive {
            incomingMessages = model.incomingMessages
            outgoingMessages = model.outgoingMessages
            trashedMessageIDs = model.trashedMessageIDs
        } else {
            incomingMessages = bootstrap.storedIncomingMessages[network.id] ?? []
            let metadata = bootstrap.storedMailboxMetadata[network.id] ?? .empty
            outgoingMessages = metadata.outgoingMessages
            trashedMessageIDs = metadata.trashedMessageIDs
        }
        return NetworkMailboxCounts(
            incoming: incomingMessages.lazy.filter { !trashedMessageIDs.contains($0.id) }.count,
            outgoing: outgoingMessages.lazy.filter {
                !trashedMessageIDs.contains($0.id) && Mailbox.outbox.includes($0)
            }.count,
            sent: outgoingMessages.lazy.filter {
                !trashedMessageIDs.contains($0.id) && Mailbox.sentItems.includes($0)
            }.count,
            trash: trashedMessageIDs.count
        )
    }
}

private struct NetworkMailboxCounts {
    let incoming: Int
    let outgoing: Int
    let sent: Int
    let trash: Int
}

private struct MacContextList: View {
    @AppStorage("net.beakr.settings.selectedTab") private var selectedSettingsTab = BeakrSettingsTab.networks.rawValue
    let bootstrap: NodeBootstrapModel
    let sidebarRoute: MacSidebarRoute?
    let networks: [NetworkSummary]
    let selectedCategory: MacSidebarCategory
    @Binding var detailRoute: MacDetailRoute?
    let incomingMessages: [IncomingMessage]
    let outgoingMessages: [OutgoingMessage]
    let memberDirectory: MacMemberDirectorySnapshot
    let focus: FocusState<MacNavigationColumn?>.Binding
    let canRemoveDevice: (MacMemberDetail) -> Bool
    let requestDeviceRemoval: (MacMemberDetail) -> Void
    let displayName: (UUID) -> String
    let isRead: (UUID) -> Bool
    let setRead: (Bool, UUID) -> Void
    let isFlagged: (UUID) -> Bool
    let flagColor: (UUID) -> MessageFlagColor?
    let setFlag: (MessageFlagColor?, UUID) -> Void
    let reply: (UUID) -> Void
    let replyAll: (UUID) -> Void
    let canReply: (UUID) -> Bool
    let forward: (MailMessageSelection) -> Void
    let canForward: Bool
    let moveIncomingToTrash: (UUID) -> Void
    let moveOutgoingToTrash: (UUID) -> Void
    let restoreMessage: (UUID) -> Void
    let permanentlyDeleteIncoming: (UUID) -> Void
    let permanentlyDeleteOutgoing: (UUID) -> Void

    var body: some View {
        Group {
            switch sidebarRoute {
            case .network:
                MacSettingsSectionList()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            case .mailbox(let mailbox):
                MacMessageList(
                    mailbox: mailbox,
                    detailRoute: $detailRoute,
                    incomingMessages: incomingMessages,
                    outgoingMessages: outgoingMessages,
                    focus: focus,
                    displayName: displayName,
                    isRead: isRead,
                    setRead: setRead,
                    isFlagged: isFlagged,
                    flagColor: flagColor,
                    setFlag: setFlag,
                    reply: reply,
                    replyAll: replyAll,
                    canReply: canReply,
                    forward: forward,
                    canForward: canForward,
                    moveIncomingToTrash: moveIncomingToTrash,
                    moveOutgoingToTrash: moveOutgoingToTrash,
                    restoreMessage: restoreMessage,
                    permanentlyDeleteIncoming: permanentlyDeleteIncoming,
                    permanentlyDeleteOutgoing: permanentlyDeleteOutgoing
                )
            case .members(let networkID, let availability):
                MacMemberList(
                    members: memberDirectory.members(
                        networkID: networkID,
                        availability: availability
                    ),
                    availability: availability,
                    focus: focus,
                    detailRoute: $detailRoute,
                    canRemoveDevice: canRemoveDevice,
                    requestDeviceRemoval: requestDeviceRemoval
                )
            case nil:
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "sidebar.left",
                    description: Text("Choose a mailbox or member status from the sidebar.")
                )
            }
        }
        .navigationTitle(columnTitle)
        .navigationSubtitle(columnSubtitle)
    }

    private var columnTitle: Text {
        switch sidebarRoute {
        case .network(let id): Text(networks.first(where: { $0.id == id })?.displayName ?? "Network")
        case .mailbox(let mailbox): Text(mailbox.mailbox.title)
        case .members(let id, let availability):
            Text(memberDirectory.members(networkID: id, availability: availability).first?.isActiveNetwork == false
                 ? "UnObserved" : availability.title)
        case nil: Text("Select a Network")
        }
    }

    private var columnSubtitle: Text {
        switch sidebarRoute {
        case .mailbox(let mailbox):
            let count = mailbox.mailbox == .inbox ? incomingMessages.count
                : mailbox.mailbox == .trash ? incomingMessages.count + outgoingMessages.count : outgoingMessages.count
            return count == 1 ? Text("1 message") : Text("\(count) messages")
        case .members(let id, let availability):
            let count = memberDirectory.members(networkID: id, availability: availability).count
            return count == 1 ? Text("1 device") : Text("\(count) devices")
        case .network, nil: return Text("")
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
    let setRead: (Bool, UUID) -> Void
    let isFlagged: (UUID) -> Bool
    let flagColor: (UUID) -> MessageFlagColor?
    let setFlag: (MessageFlagColor?, UUID) -> Void
    let reply: (UUID) -> Void
    let replyAll: (UUID) -> Void
    let canReply: (UUID) -> Bool
    let forward: (MailMessageSelection) -> Void
    let canForward: Bool
    let moveIncomingToTrash: (UUID) -> Void
    let moveOutgoingToTrash: (UUID) -> Void
    let restoreMessage: (UUID) -> Void
    let permanentlyDeleteIncoming: (UUID) -> Void
    let permanentlyDeleteOutgoing: (UUID) -> Void
    @State private var selectedRoutes: Set<MacDetailRoute> = []
    @ScaledMetric(relativeTo: .body) private var messageRowMinimumHeight = 64

    var body: some View {
        List(selection: $selectedRoutes) {
            messageRows
        }
        .contextMenu(forSelectionType: MacDetailRoute.self) { routes in
            selectionContextMenu(for: routes)
        }
        .onChange(of: selectedRoutes) { _, routes in
            synchronizeDetailRoute(with: routes)
        }
        .onChange(of: detailRoute, initial: true) { _, route in
            synchronizeListSelection(with: route)
        }
        .onChange(of: mailbox) { _, _ in
            synchronizeListSelection(with: detailRoute)
        }
        .environment(\.defaultMinListRowHeight, messageRowMinimumHeight)
        .focused(focus, equals: .content)
        .listStyle(.inset)
        .overlay {
            if mailbox.mailbox == .inbox && incomingMessages.isEmpty {
                MacColumnEmptyState("No Items", systemImage: "tray.and.arrow.down")
            } else if mailbox.mailbox == .trash && incomingMessages.isEmpty && outgoingMessages.isEmpty {
                MacColumnEmptyState("No Items", systemImage: "trash")
            } else if mailbox.mailbox != .inbox && mailbox.mailbox != .trash && outgoingMessages.isEmpty {
                MacColumnEmptyState("No Items", systemImage: mailbox.mailbox.systemImage)
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
    }

    @ViewBuilder
    private var messageRows: some View {
        switch mailbox.mailbox {
        case .inbox:
            incomingMessageRows
        case .outbox, .sentItems:
            outgoingMessageRows
        case .trash:
            trashedIncomingMessageRows
            trashedOutgoingMessageRows
        }
    }

    private var incomingMessageRows: some View {
        ForEach(incomingMessages) { message in
            IncomingMailRow(
                sender: message.source.map(displayName) ?? "Unknown Sender",
                subject: message.subject,
                preview: message.preview,
                receivedAt: message.receivedAt,
                isRead: isRead(message.id),
                isFlagged: isFlagged(message.id),
                flagColor: flagColor(message.id)
            )
            .tag(MacDetailRoute.message(.incoming(message.id)))
        }
    }

    private var outgoingMessageRows: some View {
        ForEach(outgoingMessages) { message in
            OutgoingMailRow(
                recipient: displayName(message.destination),
                messageBody: message.body,
                state: message.state,
                deliveredAt: message.deliveredAt,
                openedAt: message.openedAt,
                isFlagged: isFlagged(message.id),
                flagColor: flagColor(message.id)
            )
            .tag(MacDetailRoute.message(.outgoing(message.id)))
        }
    }

    private var trashedIncomingMessageRows: some View {
        ForEach(incomingMessages) { message in
            IncomingMailRow(
                sender: message.source.map(displayName) ?? "Unknown Sender",
                subject: message.subject,
                preview: message.preview,
                receivedAt: message.receivedAt,
                isRead: isRead(message.id),
                isFlagged: isFlagged(message.id),
                flagColor: flagColor(message.id)
            )
            .tag(MacDetailRoute.message(.incoming(message.id)))
        }
    }

    private var trashedOutgoingMessageRows: some View {
        ForEach(outgoingMessages) { message in
            OutgoingMailRow(
                recipient: displayName(message.destination),
                messageBody: message.body,
                state: message.state,
                deliveredAt: message.deliveredAt,
                openedAt: message.openedAt,
                isFlagged: isFlagged(message.id),
                flagColor: flagColor(message.id)
            )
            .tag(MacDetailRoute.message(.outgoing(message.id)))
        }
    }

    @ViewBuilder
    private func selectionContextMenu(for routes: Set<MacDetailRoute>) -> some View {
        let incomingIDs = incomingMessageIDs(in: routes)
        let outgoingIDs = outgoingMessageIDs(in: routes)
        let messageIDs = incomingIDs + outgoingIDs
        let allIncomingAreRead = !incomingIDs.isEmpty && incomingIDs.allSatisfy(isRead)

        if routes.count == 1, let route = routes.first {
            Button("Open") {
                detailRoute = route
            }

            if mailbox.contextID == nil, !incomingIDs.isEmpty {
                if let id = incomingIDs.first {
                    Button("Reply") { reply(id) }
                        .disabled(!canReply(id))
                    Button("Reply All") { replyAll(id) }
                        .disabled(!canReply(id))
                    Button("Forward") { forward(.incoming(id)) }
                        .disabled(!canForward)
                }
            }

            Divider()
        }

        if mailbox.contextID == nil, !incomingIDs.isEmpty {
            Button(
                allIncomingAreRead ? "Mark as Unread" : "Mark as Read",
                systemImage: allIncomingAreRead ? "envelope.badge" : "envelope.open"
            ) {
                incomingIDs.forEach { setRead(!allIncomingAreRead, $0) }
            }
        }

        if mailbox.contextID == nil, !routes.isEmpty {
            if mailbox.mailbox == .trash {
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    incomingIDs.forEach(restoreMessage)
                    outgoingIDs.forEach(restoreMessage)
                }
                Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                    incomingIDs.forEach(permanentlyDeleteIncoming)
                    outgoingIDs.forEach(permanentlyDeleteOutgoing)
                }
            } else {
                Button("Delete", systemImage: "trash") {
                    incomingIDs.forEach(moveIncomingToTrash)
                    outgoingIDs.forEach(moveOutgoingToTrash)
                }
            }

            Divider()

            Text("Flag:")
            ControlGroup {
                Button {
                    messageIDs.forEach { setFlag(nil, $0) }
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Clear Flag")

                ForEach(MessageFlagColor.appleMailMenuOrder, id: \.self) { color in
                    Button {
                        messageIDs.forEach { setFlag(color, $0) }
                    } label: {
                        Image(nsImage: color.macFlagImage)
                    }
                    .help(String(localized: color.title))
                }
            }
            .controlGroupStyle(.palette)
        }
    }

    private func synchronizeDetailRoute(with routes: Set<MacDetailRoute>) {
        if routes.isEmpty {
            if detailRoute?.messageSelection != nil {
                detailRoute = nil
            }
        } else if let detailRoute, routes.contains(detailRoute) {
            return
        } else {
            detailRoute = orderedRoutes.first(where: routes.contains)
        }
    }

    private func synchronizeListSelection(with route: MacDetailRoute?) {
        guard let route, orderedRoutes.contains(route) else {
            selectedRoutes = []
            return
        }
        if !selectedRoutes.contains(route) {
            selectedRoutes = [route]
        }
    }

    private var orderedRoutes: [MacDetailRoute] {
        switch mailbox.mailbox {
        case .inbox:
            incomingMessages.map { .message(.incoming($0.id)) }
        case .outbox, .sentItems:
            outgoingMessages.map { .message(.outgoing($0.id)) }
        case .trash:
            incomingMessages.map { .message(.incoming($0.id)) }
                + outgoingMessages.map { .message(.outgoing($0.id)) }
        }
    }

    private func incomingMessageIDs(in routes: Set<MacDetailRoute>) -> [UUID] {
        incomingMessages.compactMap { message in
            routes.contains(.message(.incoming(message.id))) ? message.id : nil
        }
    }

    private func outgoingMessageIDs(in routes: Set<MacDetailRoute>) -> [UUID] {
        outgoingMessages.compactMap { message in
            routes.contains(.message(.outgoing(message.id))) ? message.id : nil
        }
    }
}

private struct MacMemberList: View {
    @State private var appleNetworkSnapshot = AppleNetworkSnapshot.unknown
    let members: [MacMemberDetail]
    let availability: MacMemberAvailability
    let focus: FocusState<MacNavigationColumn?>.Binding
    @Binding var detailRoute: MacDetailRoute?
    let canRemoveDevice: (MacMemberDetail) -> Bool
    let requestDeviceRemoval: (MacMemberDetail) -> Void

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

                let address = (member.isLocalDevice ? appleNetworkSnapshot.localIPv4Address : (member.isOnline ? member.deviceIPAddress : nil)) ?? "--"
                Text(member.isLocalDevice
                     ? LocalizedStringResource("This Device IP: \(address)")
                     : LocalizedStringResource("Device IP: \(address)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help((member.isLocalDevice ? appleNetworkSnapshot.localIPv4Address : member.deviceIPAddress) ?? "--")

                if let notice = member.membershipNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if !member.isOnline, let lastSeen = member.lastSeen {
                    Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tag(MacDetailRoute.device(member.networkID, member.deviceID))
            .accessibilityElement(children: .combine)
            .accessibilityValue(!member.isActiveNetwork ? "UnObserved" : (member.isOnline ? "Online" : "Offline"))
            .contextMenu {
                Button(
                    "Remove from Network…",
                    systemImage: "person.crop.circle.badge.xmark",
                    role: .destructive
                ) {
                    requestDeviceRemoval(member)
                }
                .disabled(!canRemoveDevice(member))
            }
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
        .task {
            for await path in CurrentInternetRouteProbe.updates() {
                let snapshot = await AppleNetworkSnapshot.capture(path: path)
                guard !Task.isCancelled else { return }
                appleNetworkSnapshot = snapshot
            }
        }
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
    let bootstrap: NodeBootstrapModel
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
                MacDeviceProperties(member: member, directory: memberDirectory, bootstrap: bootstrap)
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
                .task(id: message.id) {
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
                    Button("Refresh Network Credentials", systemImage: "arrow.clockwise", action: refresh)
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
    let reply: () -> Void
    let replyAll: () -> Void
    let forward: () -> Void
    let delete: () -> Void
    let setFlag: (MessageFlagColor?) -> Void
    let canReply: Bool
    let canForward: Bool
    let canDelete: Bool
    let canFlag: Bool
    let flagColor: MessageFlagColor?

    @ViewBuilder
    private var toolbarFlagIcon: some View {
        if let flagColor {
            Image(nsImage: flagColor.macFlagImage)
        } else {
            Image(systemName: "flag")
        }
    }

    var body: some ToolbarContent {
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

                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                    .disabled(!canDelete)
                    .help("Move the selected message to Trash")

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
            ControlGroup {
                Button {
                    setFlag(flagColor == nil ? .orange : nil)
                } label: {
                    toolbarFlagIcon
                }
                .help(flagColor == nil ? "Flag the selected message" : "Clear the selected message’s flag")

                Menu {
                    Picker(
                        "Flag Colour",
                        selection: Binding(
                            get: { flagColor },
                            set: { setFlag($0) }
                        )
                    ) {
                        ForEach(MessageFlagColor.appleMailMenuOrder, id: \.self) { color in
                            Label {
                                Text(color.title)
                            } icon: {
                                Image(nsImage: color.macFlagImage)
                            }
                            .tag(Optional(color))
                        }
                    }
                    .pickerStyle(.inline)

                    Divider()

                    Button("Clear Flag") {
                        setFlag(nil)
                    }
                    .disabled(flagColor == nil)

                    Button("Toggle Flag") {
                        setFlag(flagColor == nil ? .orange : nil)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .accessibilityLabel("Flag options")
                }
                .menuIndicator(.hidden)
                .help("Choose a flag colour")
            }
            .controlGroupStyle(.navigation)
            .disabled(!canFlag)
        }
        .sharedBackgroundVisibility(.visible)
    }
}

private struct DevicePropertiesToolbar: ToolbarContent {
    let removeDevice: () -> Void
    let canRemoveDevice: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu("Device Actions", systemImage: "ellipsis.circle") {
                Button("Remove from Network…", systemImage: "person.crop.circle.badge.xmark", role: .destructive, action: removeDevice)
                    .disabled(!canRemoveDevice)
            }
            .help("Device actions")
        }
    }
}

enum BeakrSettingsTab: String {
    case device
    case networks
    case services
}

private struct MacSettingsSectionList: View {
    @AppStorage("net.beakr.settings.selectedTab") private var selectedTab = BeakrSettingsTab.networks.rawValue

    var body: some View {
        List(selection: $selectedTab) {
            Label("This Device", systemImage: "desktopcomputer")
                .tag(BeakrSettingsTab.device.rawValue)
            Label("Network", systemImage: "network")
                .tag(BeakrSettingsTab.networks.rawValue)
            Label("Services", systemImage: "square.stack.3d.up")
                .tag(BeakrSettingsTab.services.rawValue)
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("columnTwoSettingsList")
    }
}

@MainActor
struct BeakrSettingsView: View {
    private let embeddedNetworkID: NetworkProfileID?
    @State private var bootstrap: NodeBootstrapModel
    @State private var friendlyNameDraft = ""
    @State private var isApplyingName = false
    @State private var isRenamingDevice = false
    @State private var nameFeedback: String?
    @AppStorage("net.beakr.settings.selectedTab") private var selectedTab = BeakrSettingsTab.networks.rawValue
    @AppStorage(ApplicationLANRuntimeManager.remembersPreviouslyConnectedDevicesKey)
    private var remembersPreviouslyConnectedDevices = true

    init(bootstrap: NodeBootstrapModel, embeddedNetworkID: NetworkProfileID? = nil) {
        _bootstrap = State(initialValue: bootstrap)
        self.embeddedNetworkID = embeddedNetworkID
    }

    var body: some View {
        Group {
            if embeddedNetworkID != nil {
                settingsDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(sectionTitle)
                    .navigationSubtitle("")
            } else {
                HSplitView {
                    List(selection: $selectedTab) {
                        Label("This Device", systemImage: "desktopcomputer")
                            .tag(BeakrSettingsTab.device.rawValue)
                        Label("Networks", systemImage: "network")
                            .tag(BeakrSettingsTab.networks.rawValue)
                        Label("Services", systemImage: "square.stack.3d.up")
                            .tag(BeakrSettingsTab.services.rawValue)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 170, idealWidth: 200, maxWidth: 260)
                    .accessibilityIdentifier("settingsPanePicker")

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("This Mac: \(bootstrap.deviceDisplayName)")
                                .font(.headline)
                            Spacer()
                        }
                        .padding()
                        Divider()
                        settingsDetail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minWidth: 540)
                }
                .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity,
                       minHeight: 560, idealHeight: 650, maxHeight: .infinity)
            }
        }
        .onChange(of: remembersPreviouslyConnectedDevices, initial: true) { _, enabled in
            Task { await bootstrap.setRemembersPreviouslyConnectedDevices(enabled) }
        }
    }

    private var sectionTitle: Text {
        switch BeakrSettingsTab(rawValue: selectedTab) ?? .networks {
        case .device: Text("This Device")
        case .networks: Text("Network")
        case .services: Text("Services")
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch BeakrSettingsTab(rawValue: selectedTab) ?? .networks {
        case .device:
            Form {
                Section("This Device") {
                    LabeledContent("Friendly Name") {
                        HStack {
                            Text(bootstrap.deviceDisplayName)
                            Button("Rename Device", systemImage: "pencil") {
                                friendlyNameDraft = bootstrap.deviceDisplayName
                                isRenamingDevice = true
                            }
                            .labelStyle(.iconOnly)
                            .help("Rename Device")
                            .disabled(isApplyingName)
                        }
                    }
                    if let nameFeedback {
                        Text(nameFeedback).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("This name identifies this Mac. Network identities and membership are shown under Networks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Device Discovery Preferences") {
                    Toggle("Remember previously connected devices", isOn: $remembersPreviouslyConnectedDevices)
                    Text("Keeps authenticated device names and last-seen information available while devices are offline. Message history is unaffected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("deviceSettings")
            .alert("Rename Device", isPresented: $isRenamingDevice) {
                TextField("Friendly Name", text: $friendlyNameDraft)
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    isApplyingName = true
                    bootstrap.deviceFriendlyName = friendlyNameDraft
                    Task {
                        await bootstrap.applyDeviceFriendlyName()
                        nameFeedback = bootstrap.statusMessage
                        isApplyingName = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplyingName || friendlyNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .networks:
            NetworkManagerWindow(
                bootstrap: bootstrap,
                embeddedNetworkID: embeddedNetworkID
            )
                .accessibilityIdentifier("networkSettings")
        case .services:
            MessagingServicesView(bootstrap: bootstrap)
        }
    }
}

@MainActor
private struct AuthorityHostingControls: View {
    let bootstrap: NodeBootstrapModel
    let profileID: NetworkProfileID

    private var isAuthorityOn: Bool {
        let state = bootstrap.authorityHostingStates[profileID] ?? .stopped
        return state == .running || state == .stopping
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Network Authority")
                Spacer()
                Text(isAuthorityOn ? "On" : "Off")
                Toggle("Authority Service", isOn: Binding(
                    get: { isAuthorityOn },
                    set: { enabled in
                        Task { await bootstrap.setAuthorityHosting(enabled, for: profileID) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(bootstrap.authorityHostingBusy)
            }
            if let failure = bootstrap.authorityHostingFailures[profileID] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("On: This device provides the network’s Authority Service. It can process device registration requests and supply updated credentials and revocation records.")
                Text("Off: Authority Services are not available from this device. Devices with valid credentials and current revocation records may continue to function. Devices requiring updates will have to wait until an Authority Service comes online.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct NetworkManagerWindow: View {
    @Environment(\.dismiss) private var dismiss
    private let onNetworkCreated: ((NetworkProfileID) -> Void)?
    private let creatingNetwork: Bool?
    private let embeddedNetworkID: NetworkProfileID?
    @State private var bootstrap: NodeBootstrapModel
    @AppStorage("net.beakr.networkManager.selectedNetworkID") private var persistedNetworkID = ""
    @State private var selectedNetworkID: NetworkProfileID?
    @State private var editorMode: NetworkEditorMode = .details
    @State private var editedName = ""
    @State private var isRenamingNetwork = false
    private var displayedInvitationJSON: String {
        selectedNetwork.map { bootstrap.administration(for: $0.id).invitationJSON } ?? ""
    }
    @AppStorage("net.beakr.settings.networkRequest") private var networkSettingsRequest = ""
    @State private var pendingDeletion: OwnedNetworkSummary?
    @State private var pendingDeparture: NetworkSummary?
    @State private var pendingAuthorityReset: NetworkSummary?
    @State private var creationAttempted = false
    @State private var presentedSectionInformation: NetworkSectionInformation?

    init(bootstrap: NodeBootstrapModel, embeddedNetworkID: NetworkProfileID? = nil, creatingNetwork: Bool? = nil, onNetworkCreated: ((NetworkProfileID) -> Void)? = nil) {
        _bootstrap = State(initialValue: bootstrap)
        self.onNetworkCreated = onNetworkCreated
        self.creatingNetwork = creatingNetwork
        self.embeddedNetworkID = embeddedNetworkID
        _selectedNetworkID = State(initialValue: embeddedNetworkID)
    }

    var body: some View {
        detailContent
        .accessibilityIdentifier("networkManagerWindow")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $presentedSectionInformation) { information in
            NetworkSectionInformationView(information: information)
        }
        .alert(
            "Are you sure you want to reset the Network Authority?",
            isPresented: Binding(
                get: { pendingAuthorityReset != nil },
                set: { if !$0 { pendingAuthorityReset = nil } }
            ),
            presenting: pendingAuthorityReset
        ) { network in
            Button("Reset Authority", role: .destructive) {
                pendingAuthorityReset = nil
                Task { await bootstrap.resetOwnedNetworkAuthority(network.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { network in
            Text("Reset invalidates existing device access credentials for \(network.displayName) and creates new authority credentials on this device. Every other device must join again with a new invitation. Existing invitations and pending join requests become invalid.\n\nStored messages and other application data are not deleted.")
        }
        .alert(
            "Rename Network",
            isPresented: $isRenamingNetwork,
            presenting: selectedNetwork
        ) { network in
            TextField("Network Name", text: $editedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename(network) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRename(network))
        } message: { network in
            Text("Enter a new name for \(network.displayName).")
        }
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
            Button("Forget and Keep Data", role: .destructive) {
                pendingDeparture = nil
                Task {
                    await bootstrap.forgetJoinedNetwork(
                        network.id,
                        dataDisposition: .keepLocalData
                    )
                }
            }
            Button("Forget and Delete Data", role: .destructive) {
                pendingDeparture = nil
                Task {
                    await bootstrap.forgetJoinedNetwork(
                        network.id,
                        dataDisposition: .deleteLocalData
                    )
                }
            }
            Button("Keep Network", role: .cancel) {}
        } message: { network in
            Text(forgetNetworkMessage(
                for: network,
                deviceName: "Mac",
                connectivity: bootstrap.activeNetworkConnectivity
            ))
        }
        .onAppear {
            if let creatingNetwork {
                if creatingNetwork { bootstrap.prepareForNetworkCreation() }
                editorMode = creatingNetwork ? .create : .join
            } else {
                restoreSelection()
            }
        }
        .task(id: selectedNetwork?.id) {
            if let id = selectedNetwork?.id { await bootstrap.refreshPendingEnrollmentRequests(for: id) }
        }
        .onChange(of: networkSettingsRequest) { _, _ in
            guard embeddedNetworkID == nil else { return }
            editorMode = .details
            restoreSelection()
        }
        .onChange(of: persistedNetworkID) { _, _ in
            guard embeddedNetworkID == nil else { return }
            editorMode = .details
            restoreSelection()
        }
        .onChange(of: selectedNetworkID) { _, selection in
            persistedNetworkID = selection?.rawValue.uuidString ?? ""
            if selection != nil || editorMode != .create {
                editorMode = .details
            }
            editedName = selectedNetwork?.displayName ?? ""
        }
        .onChange(of: bootstrap.networks) { _, _ in
            guard editorMode != .create else { return }
            if editorMode != .details,
               let activeNetwork = bootstrap.networks.first(where: \.isActive) {
                selectedNetworkID = activeNetwork.id
            } else if let selectedNetworkID,
                      !bootstrap.networks.contains(where: { $0.id == selectedNetworkID }) {
                self.selectedNetworkID = nil
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch editorMode {
        case .details:
            networkInstances
        case .create:
            createNetworkView
        case .join:
            joinNetworkView
        }
    }

    private var networkInstances: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(selectedNetwork?.displayName ?? "Networks")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if let network = selectedNetwork {
                        if network.isActive { ActiveMessagingIndicator(health: network.messagingHealth, message: network.messagingHealthMessage) }
                        if network.isHostingAuthority {
                            AuthorityHostingIndicator(state: bootstrap.authorityHostingStates[network.id])
                        }
                    }

                }
                if let network = selectedNetwork {
                    networkInformationPane(network)
                        .id(network.id)
                } else if bootstrap.networks.isEmpty {
                    ContentUnavailableView("No Networks", systemImage: "network.slash",
                        description: Text("Create or join a network to get started."))
                } else {
                    ContentUnavailableView("Select a Network", systemImage: "network",
                        description: Text("Select a network in the main window to view its settings."))
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(selectedNetworkID)
    }

    private func networkInformationPane(_ network: NetworkSummary) -> some View {
        let isStarting = network.isActive
            && bootstrap.state.isPreparingNetwork(connectivity: bootstrap.activeNetworkConnectivity)

        return VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Name") {
                        HStack(spacing: 6) {
                            if network.isActive {
                                MacNetworkStatusIcon(
                                    connectivity: bootstrap.activeNetworkConnectivity,
                                    systemImage: network.canManageNetwork
                                        ? "network.badge.shield.half.filled"
                                        : "network"
                                )
                                .accessibilityHidden(true)
                            } else {
                                Image(systemName: "network.slash")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }

                            Text(network.displayName)
                                .foregroundStyle(
                                    network.isActive
                                        ? bootstrap.activeNetworkConnectivity.networkForegroundStyle
                                        : AnyShapeStyle(Color.secondary)
                                )
                            if network.isHostingAuthority {
                                Button("Rename Network", systemImage: "pencil") {
                                    editedName = network.displayName
                                    isRenamingNetwork = true
                                }
                                .labelStyle(.iconOnly)
                                .help("Rename Network")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Divider()

                    NetworkInformationRow("Network ID") {
                        Text(network.networkID.rawValue.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Divider()
                    NetworkCredentialDetailsView(bootstrap: bootstrap, network: network)

                    if network.isHostingAuthority {
                        Divider()
                        AuthorityHostingControls(bootstrap: bootstrap, profileID: network.id)
                        if network.isActive {
                            Button("Reset Authority…", role: .destructive) {
                                pendingAuthorityReset = network
                            }
                            .disabled(bootstrap.state == .securing)
                            .accessibilityIdentifier("replaceNetworkAuthorityButton")
                            Text("Resets this network’s authority credentials on this device. Every other device loses access and must join again using a new invitation. Existing invitations and pending join requests become invalid. You’ll be asked to confirm before proceeding.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if bootstrap.networkSessions.first(where: { $0.id == network.id })?.lastError != nil {
                        Divider()
                        NetworkLastErrorDisclosure(
                            message: bootstrap.networkSessions.first(where: { $0.id == network.id })?.lastError
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox("Devices in This Network") {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup {
                        NetworkAddressesContent(
                            localName: bootstrap.deviceDisplayName,
                            localID: bootstrap.localNodeID(for: network.id),
                            isNetworkActive: network.isActive,
                            localDeviceIsMember: !network.isActive || bootstrap.state == .ready,
                            members: bootstrap.members(for: network),
                            onlineMemberIDs: network.isActive ? bootstrap.onlineMemberIDs : [],
                            isLocalDeviceOnline: network.isActive && bootstrap.state == .ready && bootstrap.activeNetworkConnectivity.isLocalDeviceOnline,
                            authorityDeviceName: network.isActive ? bootstrap.activeAuthorityDeviceName : nil,
                            isLocalDeviceAuthority: network.isHostingAuthority,
                            localCanManageNetwork: network.canManageNetwork,
                            membershipNotice: (bootstrap.savedMemberships[network.id] ?? .unavailable).notice,
                            isStarting: isStarting
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Devices")
                            NetworkSectionInformationButton(
                                information: .devices,
                                show: { presentedSectionInformation = $0 }
                            )
                        }
                    }

                    if network.isHostingAuthority {
                        DisclosureGroup("Device Registration") {
                            VStack(alignment: .leading, spacing: 16) {
                                networkInvitationPane(network)
                            }
                            .padding(.top, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 12) {
                if !network.isActive {
                    Button("Use for Messaging", systemImage: "bubble.left.fill") {
                        Task { await bootstrap.switchNetwork(to: network.id) }
                    }
                    .disabled(bootstrap.state == .securing || bootstrap.state == .starting)
                }

            }
        }
    }

    @ViewBuilder
    private func networkInvitationPane(_ network: NetworkSummary) -> some View {
        if network.isHostingAuthority {
            DisclosureGroup("Invitation") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Generate an Invitation")
                        .font(.headline)

                    Button(
                        displayedInvitationJSON.isEmpty ? "Generate Invitation" : "Generate New Invitation",
                        systemImage: "plus.viewfinder"
                    ) {
                        Task { await bootstrap.createInvitation(for: network.id) }
                    }
                    .disabled(bootstrap.authorityHostingStates[network.id] != .running || bootstrap.authorityHostingBusy)

                    if bootstrap.invitationIsConsumed(displayedInvitationJSON) {
                        UsedInvitationNotice()
                    } else if !displayedInvitationJSON.isEmpty {
                        InvitationQRCodeView(invitation: displayedInvitationJSON)
                            .frame(width: 320)
                            .frame(minHeight: 390)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Text("Scan the QR code, or copy or share the invitation with the joining device.")
                            .foregroundStyle(.secondary)
                        HStack {
                            InvitationCopyButton(
                                invitation: displayedInvitationJSON,
                                action: copyInvitation
                            )
                            InvitationShareLink(invitation: displayedInvitationJSON) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }

                        if let invitation = try? EnrollmentWireCodec.decode(
                            EnrollmentInvitation.self,
                            from: Data(displayedInvitationJSON.utf8)
                        ) {
                            MacInvitationTechnicalDetails(invitation: invitation)
                        }
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            DisclosureGroup("Join Request Approvals") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Refresh Join Requests", systemImage: "arrow.clockwise") {
                        Task { await bootstrap.refreshPendingEnrollmentRequests(for: network.id) }
                    }
                    .disabled(bootstrap.authorityHostingStates[network.id] != .running || bootstrap.authorityHostingBusy)

                        if bootstrap.administration(for: network.id).requests.isEmpty {
                            Text("No pending join requests.").foregroundStyle(.secondary)
                        }
                        ForEach(
                            bootstrap.administration(for: network.id).requests.sorted {
                                $0.invitation.issuedAtMilliseconds > $1.invitation.issuedAtMilliseconds
                            },
                            id: \.requestID
                        ) { request in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(request.deviceDisplayName ?? "Device wants to join")
                                        .font(.headline)
                                    Text("Node ID: \(request.nodeID.rawValue.uuidString)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text("Request: \(request.requestID.uuidString)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Text(
                                        Date(
                                            timeIntervalSince1970: Double(request.invitation.issuedAtMilliseconds) / 1_000
                                        ),
                                        format: .dateTime.hour().minute().second()
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Allow", systemImage: "person.badge.plus") {
                                    Task {
                                        await bootstrap.approveEnrollmentRequest(request.requestID, for: network.id)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(bootstrap.authorityHostingStates[network.id] != .running || bootstrap.authorityHostingBusy)
                                Button("Don’t Allow", role: .destructive) {
                                    Task {
                                        await bootstrap.rejectEnrollmentRequest(request.requestID, for: network.id)
                                    }
                                }
                                .disabled(bootstrap.authorityHostingStates[network.id] != .running || bootstrap.authorityHostingBusy)
                            }
                        }

                        if let message = bootstrap.administration(for: network.id).message {
                            Label(message, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(message.hasPrefix("Approved") ? .green : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if !bootstrap.administration(for: network.id).records.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(bootstrap.administration(for: network.id).records) { record in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(registrationDeviceName(for: record))
                                        .font(.body.weight(.medium))
                                    Text("Node ID: \(abbreviatedDeviceID(record.request.nodeID))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(
                                        Date(timeIntervalSince1970: Double(record.updatedAtMilliseconds) / 1_000),
                                        format: .dateTime.year().month().day().hour().minute()
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if let expiresAt = record.accessExpiresAtMilliseconds {
                                        Text(
                                            "Permission expires: \(Date(timeIntervalSince1970: Double(expiresAt) / 1_000).formatted(date: .abbreviated, time: .shortened))"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(registrationStatus(for: record.status))
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        Text("Device Registration History")
                        Spacer()
                        Button("Export…", systemImage: "square.and.arrow.up") {
                            exportEnrollmentAudit()
                        }
                        Button("Verify…", systemImage: "checkmark.shield") {
                            verifyEnrollmentAudit()
                        }
                    }
                }
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

    private func exportEnrollmentAudit() {
        guard let id = selectedNetwork?.id else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "beakr-enrollment-audit.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        Task { await bootstrap.exportEnrollmentAudit(to: fileURL, for: id) }
    }

    private func verifyEnrollmentAudit() {
        guard let id = selectedNetwork?.id else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        Task { await bootstrap.verifyEnrollmentAudit(at: fileURL, for: id) }
    }

    private func registrationDeviceName(for record: EnrollmentAuditRecord) -> String {
        guard selectedNetwork?.isActive == true else { return record.request.deviceDisplayName ?? "Unknown Device" }
        return bootstrap.networkMembers.first {
            $0.id == record.request.nodeID.rawValue
        }?.displayName ?? "Unknown Device"
    }

    private func abbreviatedDeviceID(_ nodeID: NodeID) -> String {
        let identifier = nodeID.rawValue.uuidString
        return "\(identifier.prefix(8))…\(identifier.suffix(5))"
    }

    private func registrationStatus(for status: EnrollmentAuditStatus) -> String {
        switch status {
        case .pending:
            "Registration Requested"
        case .approved:
            "Approved — Waiting for Device"
        case .confirmed:
            "Registered"
        case .rejected:
            "Not Approved"
        case .cancelled:
            "Cancelled"
        case .expired:
            "Expired"
        }
    }

    private var createNetworkView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Create Network")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Cancel") {
                        creationAttempted = false
                        if creatingNetwork == true {
                            dismiss()
                        } else {
                            editorMode = .details
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        MacInitialFocusTextField(
                            text: $bootstrap.networkDisplayName,
                            placeholder: "Network Name"
                        )
                        Text("This Mac will provide the new network’s Authority Service. Your current messaging network will remain selected.")
                            .foregroundStyle(.secondary)
                        Button("Create Network", systemImage: "network.badge.shield.half.filled") {
                            creationAttempted = true
                            Task {
                                await bootstrap.createNetwork()
                                if let createdID = bootstrap.lastCreatedNetworkID {
                                    creationAttempted = false
                                    if let onNetworkCreated {
                                        onNetworkCreated(createdID)
                                    } else {
                                        selectedNetworkID = createdID
                                        editorMode = .details
                                    }
                                }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            bootstrap.isCreatingNetwork ||
                            bootstrap.networkDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        if bootstrap.isCreatingNetwork {
                            ProgressView("Creating network")
                        }
                        if creationAttempted && !bootstrap.isCreatingNetwork {
                            Label(bootstrap.statusMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("createNetworkStatus")
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
                        Button("Request Network Access", systemImage: "person.badge.key") {
                            Task { await bootstrap.joinNetwork() }
                        }
                        .disabled(
                            bootstrap.state == .joiningNetwork ||
                            bootstrap.joinInvitationJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        if bootstrap.state == .joiningNetwork {
                            ProgressView("Joining network")
                        }
                        if bootstrap.hasPendingJoiningRequest {
                            Label(bootstrap.state == .failed ? "Join Needs Attention" : "Joining…", systemImage: "hourglass")
                                .foregroundStyle(.orange)
                            Text(bootstrap.statusMessage)
                                .foregroundStyle(.secondary)
                            Button("Cancel Pending Request", role: .destructive) {
                                Task { await bootstrap.cancelPendingNetworkJoin() }
                            }
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
            $bootstrap.standaloneNetworkJoinAlert,
            confirmCollision: { Task { await bootstrap.confirmCollidingNetworkJoin() } },
            confirmReattachment: { Task { await bootstrap.confirmContextReattachment() } }
        )
    }

    private var selectedNetwork: NetworkSummary? {
        if let selectedNetworkID,
           let selected = bootstrap.networks.first(where: { $0.id == selectedNetworkID }) {
            return selected
        }
        return nil
    }

    private var selectedOwnedNetwork: OwnedNetworkSummary? {
        guard let selectedNetwork else { return nil }
        return bootstrap.ownedNetworks.first { $0.id == selectedNetwork.id }
    }

    private func restoreSelection() {
        if let embeddedNetworkID {
            selectedNetworkID = bootstrap.networks.contains(where: { $0.id == embeddedNetworkID }) ? embeddedNetworkID : nil
            editedName = selectedNetwork?.displayName ?? ""
            return
        }
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
    }

    private func rename(_ network: NetworkSummary) {
        guard network.canManageNetwork, canRename(network) else { return }
        Task { await bootstrap.renameOwnedNetwork(network.id, to: editedName) }
    }

    private func canRename(_ network: NetworkSummary) -> Bool {
        let normalizedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedName.isEmpty && normalizedName != network.displayName
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

}

private struct MacInitialFocusTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> InitialFocusTextField {
        let textField = InitialFocusTextField()
        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.bezelStyle = .roundedBezel
        textField.isBezeled = true
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(_ textField: InitialFocusTextField, context: Context) {
        context.coordinator.text = $text
        if textField.currentEditor() == nil, textField.stringValue != text {
            textField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }
    }

    final class InitialFocusTextField: NSTextField {
        private var hasRequestedInitialFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !hasRequestedInitialFocus, let window else { return }
            hasRequestedInitialFocus = true
            Task { @MainActor [weak self, weak window] in
                await Task.yield()
                guard let self, let window else { return }
                window.makeFirstResponder(self)
                guard let editor = self.currentEditor() else { return }
                editor.selectedRange = NSRange(
                    location: (self.stringValue as NSString).length,
                    length: 0
                )
            }
        }
    }
}

private struct MacInvitationTechnicalDetails: View {
    let invitation: EnrollmentInvitation

    var body: some View {
        DisclosureGroup("Technical Details") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                detailRow("Network ID", value: invitation.networkID.rawValue.uuidString)
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                detailRow("Authority ID", value: invitation.authorityID.rawValue.uuidString)
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                detailRow("Authority Address", value: invitation.controlPlaneURL?.absoluteString ?? "Unavailable")
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                detailRow("Environment", value: invitation.environment)
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                detailRow("Services", value: invitation.serviceScopes.formatted())
            }
            .padding(.top, 8)
            .font(.caption)
            .textSelection(.enabled)
        }
    }

    private func detailRow(_ title: LocalizedStringKey, value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }
}

private enum NetworkEditorMode {
    case details
    case create
    case join

    var title: LocalizedStringKey {
        switch self {
        case .details: "Network Parameters"
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

private struct MacNetworksSectionHeader: View {
    let showStatusInformation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Networks")
                Button("About Network Status Colors", systemImage: "info.circle") {
                    showStatusInformation()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

        }
    }
}

#if os(macOS)
private enum MacSidebarCategory {
    case mailboxes
    case members

    var title: LocalizedStringKey {
        switch self {
        case .mailboxes: "Mailboxes"
        case .members: "Members"
        }
    }
}

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
    case network(NetworkProfileID)
    case mailbox(MailboxSelection)
    case members(NetworkProfileID, MacMemberAvailability)

    var networkID: NetworkProfileID? {
        switch self {
        case .network(let id), .members(let id, _): id
        case .mailbox(let selection): selection.networkID
        }
    }

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

private struct RevokedContextExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Access Revoked", systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.red)
            Text("The network authority revoked this device’s access. Your message history is preserved and is read-only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ArchivedContextRow: View {
    let mailbox: Mailbox

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mailbox.systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mailbox.title)
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
    var deviceIPAddress: String? = nil
    var connectionIPAddress: String? = nil
    var membershipNotice: LocalizedStringResource? = nil

    var id: UUID { deviceID }
}

private struct MacMemberDirectorySnapshot {
    let networks: [NetworkSummary]
    let localDeviceName: String
    let localDeviceID: UUID?
    let savedMemberships: [NetworkProfileID: SavedNetworkMembership]
    let localNodeIDs: [NetworkProfileID: UUID]
    let localDeviceOnline: Bool
    let activeNetworkMembers: [NetworkMemberSummary]
    let onlineMemberIDs: Set<UUID>

    func members(
        networkID: NetworkProfileID,
        availability: MacMemberAvailability
    ) -> [MacMemberDetail] {
        allMembers(networkID: networkID)
            .filter { availability == .online ? $0.isOnline : !$0.isOnline }
            .sorted {
                if $0.isLocalDevice != $1.isLocalDevice { return $0.isLocalDevice }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    func member(networkID: NetworkProfileID, deviceID: UUID) -> MacMemberDetail? {
        allMembers(networkID: networkID).first { $0.deviceID == deviceID }
    }

    private func allMembers(networkID: NetworkProfileID) -> [MacMemberDetail] {
        guard let network = networks.first(where: { $0.id == networkID }) else { return [] }
        var result: [MacMemberDetail] = []
        if let localDeviceID = localNodeIDs[networkID] {
            result.append(MacMemberDetail(
                networkID: network.id,
                networkName: network.displayName,
                deviceID: localDeviceID,
                displayName: localDeviceName,
                isLocalDevice: true,
                isOnline: network.isActive && localDeviceOnline,
                isActiveNetwork: network.isActive,
                lastSeen: nil,
                membershipNotice: network.isActive ? nil : (savedMemberships[networkID] ?? .unavailable).notice
            ))
        }
        let members = network.isActive ? activeNetworkMembers : savedMemberships[networkID]?.members ?? []
        result.append(contentsOf: members.map { member in
            MacMemberDetail(
                networkID: network.id,
                networkName: network.displayName,
                deviceID: member.id,
                displayName: member.displayName,
                isLocalDevice: false,
                isOnline: network.isActive && onlineMemberIDs.contains(member.id),
                isActiveNetwork: network.isActive,
                lastSeen: member.lastSeen,
                deviceIPAddress: network.isActive && onlineMemberIDs.contains(member.id) ? member.deviceIPAddress : nil,
                connectionIPAddress: network.isActive && onlineMemberIDs.contains(member.id) ? member.connectionIPAddress : nil,
                membershipNotice: network.isActive ? nil : (savedMemberships[networkID] ?? .unavailable).notice
            )
        })
        return result
    }
}

private struct MacDeviceProperties: View {
    let member: MacMemberDetail
    let directory: MacMemberDirectorySnapshot
    let bootstrap: NodeBootstrapModel

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: member.displayName)
                if !member.isLocalDevice {
                    LabeledContent("Reported IPv4", value: member.isOnline ? (member.deviceIPAddress ?? "--") : "--")
                    LabeledContent("Connection IP") {
                        Text(member.isOnline ? (member.connectionIPAddress ?? "--") : "--")
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LabeledContent("Node ID") {
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
                        Text(!member.isActiveNetwork ? "UnObserved" : (member.isOnline ? "Online" : "Offline"))
                            .foregroundStyle(member.isOnline ? Color.green : Color.secondary)
                    }
                }

                if let notice = member.membershipNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if !member.isOnline, let lastSeen = member.lastSeen {
                    LabeledContent("Last Seen") {
                        Text(lastSeen, format: .relative(presentation: .named))
                    }
                }
            }

            if member.isLocalDevice {
                Section("Saved Network Memberships") {
                    ForEach(directory.networks) { network in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(network.displayName) {
                                Text(network.isActive ? "Used for messaging" : "Not selected for messaging")
                            }
                            if let id = directory.localNodeIDs[network.id] {
                                Text(id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if !network.isActive {
                                Text((directory.savedMemberships[network.id] ?? .unavailable).notice)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                SharedStatusSection(profileID: member.networkID, peerID: member.deviceID, peerName: member.displayName,
                                    isOnline: member.isActiveNetwork && member.isOnline, bootstrap: bootstrap)
                    .id("\(member.networkID.rawValue)-\(member.deviceID)")
                Section("Known Network Membership") {
                    LabeledContent("Beakr'Net", value: member.networkName)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(member.displayName)
    }
}

private struct MessagingConnectivityDisclosure: View {
    let isActive: Bool
    let requiresAttention: Bool
    let connectivity: ActiveNetworkConnectivity
    let knownDeviceCount: Int
    let onlineDeviceCount: Int
    var isStarting = false
    var credentialStatus: NetworkCredentialStatus? = nil
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LabeledContent("This Device", value: isStarting ? "Connecting…" : connectivity.localDeviceStatus)
            LabeledContent("Other Devices Online", value: onlineDeviceCount.formatted())
            LabeledContent(
                isActive ? "Known Devices Offline" : "UnObserved Members",
                value: max(knownDeviceCount - onlineDeviceCount, 0).formatted()
            )
        } label: {
            LabeledContent("Messaging Connectivity") {
                if let credentialStatus {
                    Text(credentialStatus.title)
                        .foregroundStyle(credentialStatus == .preparing ? Color.secondary : Color.red)
                } else if connectivity == .localNetworkDenied {
                    Text("Local Network Permission Required")
                        .foregroundStyle(.red)
                } else if isStarting {
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                } else if requiresAttention {
                    Text("Setup Needs Attention")
                        .foregroundStyle(.red)
                } else if isActive {
                    Text("Active")
                        .foregroundStyle(.blue)
                } else {
                    Text("Not Active")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.toggle()
            }
        }
    }
}

private struct NetworkAccessRow: View {
    let canManageNetwork: Bool

    var body: some View {
        NetworkInformationRow("Role") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(canManageNetwork ? "Manager" : "Member")
                Text(canManageNetwork
                     ? "Can manage membership and invitations"
                     : "Can join this network")
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
    let isActive: Bool

    var body: some View {
        NetworkInformationRow("Authority") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(deviceName ?? "Remote Device")
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                if isHostedHere {
                    Text("This Device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

private struct MacNetworkOverviewSection: View {
    let network: NetworkSummary
    @Binding var selection: MacSidebarRoute?
    @Binding var selectedCategory: MacSidebarCategory
    let incomingCount: Int
    let outgoingCount: Int
    let sentCount: Int
    let trashCount: Int
    let onlineMemberCount: Int
    let offlineMemberCount: Int
    let activeConnectivity: ActiveNetworkConnectivity
    let authorityHostingState: AuthorityHostingState?
    let authorityHostingEnabled: Bool
    let authorityHostingBusy: Bool
    let setAuthorityHosting: (Bool) -> Void
    let membersAreAvailable: Bool
    let showDetails: () -> Void
    let makeActive: () -> Void
    let requestRemoval: () -> Void

    @State private var networkIsExpanded = false
    @State private var mailboxesAreExpanded = false
    @State private var membersAreExpanded = false

    @ViewBuilder
    var body: some View {
        networkHeader
            .tag(MacSidebarRoute.network(network.id))
            .task(id: network.isActive) {
                networkIsExpanded = network.isActive
                mailboxesAreExpanded = false
                membersAreExpanded = false
            }

        if networkIsExpanded {
            networkChildren
                .padding(.leading, 20)
        }
    }

    private var networkHeader: some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                networkIsExpanded.toggle()
            } label: {
                Image(systemName: networkIsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(networkIsExpanded ? "Collapse network" : "Expand network")
            .accessibilityValue(network.displayName)
            MacNetworkHeaderLabel(
                network: network,
                activeConnectivity: activeConnectivity,
                authorityHostingState: authorityHostingState
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                selection = .network(network.id)
            }
            .contextMenu {
                Button("View Parameters", systemImage: "info.circle") {
                    selection = .network(network.id)
                    showDetails()
                }
                Divider()
                Button("Use for Messaging", systemImage: "bubble.left.fill", action: requestMakeActive)
                    .disabled(network.isActive)
                if network.isHostingAuthority {
                    Divider()
                    Button("Start Authority Hosting", systemImage: "person.2.badge.key.fill") {
                        setAuthorityHosting(true)
                    }
                    .disabled(authorityHostingBusy || authorityHostingState == .running)
                    Button("Stop Authority Hosting", systemImage: "stop.circle") {
                        setAuthorityHosting(false)
                    }
                    .disabled(authorityHostingBusy || !authorityHostingEnabled)
                }
                Divider()
                Button(
                    network.isHostingAuthority ? "Delete Network…" : "Forget Network…",
                    systemImage: network.isHostingAuthority
                        ? "trash"
                        : "rectangle.portrait.and.arrow.right",
                    role: .destructive,
                    action: requestRemoval
                )
            }
        }
    }

    @ViewBuilder
    private var networkChildren: some View {
        DisclosureGroup(isExpanded: $membersAreExpanded) {
            MacSidebarStatusLabel("Online", systemImage: "circle.fill")
                .foregroundStyle(membersAreAvailable ? Color.primary : Color.secondary)
                .badge(onlineMemberCount)
                .tag(MacSidebarRoute.members(network.id, .online))

            MacSidebarStatusLabel(network.isActive ? "Offline" : "UnObserved", systemImage: "circle")
                .foregroundStyle(.secondary)
                .badge(offlineMemberCount)
                .tag(MacSidebarRoute.members(network.id, .offline))
        } label: {
            Label("Members", systemImage: "shareplay")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedCategory = .members
                    selection = nil
                    membersAreExpanded.toggle()
                }
        }

        DisclosureGroup(isExpanded: $mailboxesAreExpanded) {
            Label("Inbox", systemImage: "tray.and.arrow.down")
                .badge(incomingCount)
                .tag(MacSidebarRoute.mailbox(
                    MailboxSelection(networkID: network.id, mailbox: .inbox)
                ))

            Label("Outbox", systemImage: "tray.and.arrow.up")
                .badge(outgoingCount)
                .tag(MacSidebarRoute.mailbox(
                    MailboxSelection(networkID: network.id, mailbox: .outbox)
                ))

            Label("Sent Items", systemImage: "paperplane")
                .badge(sentCount)
                .tag(MacSidebarRoute.mailbox(
                    MailboxSelection(networkID: network.id, mailbox: .sentItems)
                ))

            Label("Trash", systemImage: "trash")
                .badge(trashCount)
                .tag(MacSidebarRoute.mailbox(
                    MailboxSelection(networkID: network.id, mailbox: .trash)
                ))
        } label: {
            Label("Mailboxes", systemImage: "tray.2")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedCategory = .mailboxes
                    selection = nil
                    mailboxesAreExpanded.toggle()
                }
        }

    }


    private func requestMakeActive() {
        if network.isActive {
            NSSound.beep()
        } else {
            makeActive()
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

private struct AuthorityHostingIndicator: View {
    let state: AuthorityHostingState?
    var showsTitle = false

    private var title: LocalizedStringResource {
        switch state {
        case .running: "Authority Host On — This Mac"
        case .stopped: "Authority Host Off — This Mac"
        case .starting: "Authority Host Starting — This Mac"
        case .stopping: "Authority Host Stopping — This Mac"
        case .failed: "Authority Host Failed — Open Networks → Network Authority"
        case nil: "Authority Host Checking — This Mac"
        }
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .stopped, nil: .secondary
        case .starting, .stopping: .orange
        case .failed: .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state == .failed
                ? "exclamationmark.triangle.fill"
                : (state == .running ? "person.2.badge.key.fill" : "person.2.badge.key"))
                .fixedSize()
                .symbolEffect(.pulse, isActive: state == nil || state == .starting || state == .stopping)
            if showsTitle {
                Text(title)
            }
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }
}

private struct MacNetworkHeaderLabel: View {
    let network: NetworkSummary
    let activeConnectivity: ActiveNetworkConnectivity
    let authorityHostingState: AuthorityHostingState?
    @State private var appleNetworkSnapshot = AppleNetworkSnapshot.unknown

    private var foregroundStyle: AnyShapeStyle {
        guard network.isActive else { return AnyShapeStyle(.secondary) }
        return activeConnectivity.networkForegroundStyle
    }

    private var deviceAddress: LocalizedStringResource {
        if let address = appleNetworkSnapshot.localIPv4Address {
            return "This Device IP: \(address)"
        }
        return appleNetworkSnapshot.hasChecked ? "This Device IP: Unavailable" : "This Device IP: Checking…"
    }

    private var connectionProgress: LocalizedStringResource {
        guard network.isActive else { return "Messaging inactive" }
        if let status = network.credentialStatus { return status.title }
        switch activeConnectivity {
        case .connected(let peerCount): return "\(peerCount + 1) Devices Online"
        case .readyNoPeers: return "1 Device Online"
        case .discoveringPeers: return "Finding devices…"
        case .reconnecting: return "Checking connection…"
        case .inactive: return "No Beakr network detected"
        case .localNetworkDenied: return "Local Network Permission Required"
        case .failed: return "Connection failed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: network.isActive
                ? (network.canManageNetwork ? "network.badge.shield.half.filled" : "network")
                : "network.slash")
                .fixedSize()
                .foregroundStyle(foregroundStyle)
                .accessibilityHidden(true)
                .symbolEffect(
                    .pulse,
                    options: .repeating.speed(0.7),
                    isActive: network.isActive && activeConnectivity.isTransitioning
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(network.displayName)
                    .fontWeight(.semibold)
                    .foregroundStyle(foregroundStyle)
                Text(deviceAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(Text(deviceAddress))
                Text(connectionProgress)
                    .font(.subheadline)
                    .foregroundStyle(activeConnectivity == .localNetworkDenied ? Color.red : Color.secondary)
                    .lineLimit(activeConnectivity == .localNetworkDenied ? nil : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if network.isActive {
                ActiveMessagingIndicator(health: network.messagingHealth, message: network.messagingHealthMessage)
            }
            if network.isHostingAuthority {
                AuthorityHostingIndicator(state: authorityHostingState)
            }
        }
        .accessibilityElement(children: .combine)
        .task {
            for await path in CurrentInternetRouteProbe.updates() {
                let snapshot = await AppleNetworkSnapshot.capture(path: path)
                guard !Task.isCancelled else { return }
                appleNetworkSnapshot = snapshot
            }
        }
    }
}
#endif

private enum Mailbox: Hashable {
    case inbox
    case outbox
    case sentItems
    case trash

    var title: LocalizedStringKey {
        switch self {
        case .inbox: "Inbox"
        case .outbox: "Outbox"
        case .sentItems: "Sent Items"
        case .trash: "Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.and.arrow.down"
        case .outbox: "tray.and.arrow.up"
        case .sentItems: "paperplane"
        case .trash: "trash"
        }
    }

    func includes(_ message: OutgoingMessage) -> Bool {
        switch self {
        case .inbox:
            false
        case .outbox:
            message.state == .queued || message.state == .sending || message.state == .failed
        case .sentItems:
            message.state == .sent || message.state == .delivered
        case .trash:
            false
        }
    }
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

// Logs UI decisions on appearance and input changes, never from body evaluation.
// Values supplied here are operational state only; omit names and user content.
private struct NetworkIndicatorTraceModifier: ViewModifier {
    let source: String
    let details: String
    @State private var previousChange: ContinuousClock.Instant?

    func body(content: Content) -> some View {
        content.onChange(of: details, initial: true) { _, newValue in
            let now = ContinuousClock.now
            let interval = previousChange.map { String(describing: $0.duration(to: now)) } ?? "initial"
            let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
            BeakrDiagnosticLog.emit("indicator source=\(source) uptimeSeconds=\(uptime) sincePrevious=\(interval) \(newValue)", logger: BeakrDiagnosticLog.connectivity)
            previousChange = now
        }
    }
}

private extension View {
    func traceNetworkIndicator(_ source: String, details: String) -> some View {
        modifier(NetworkIndicatorTraceModifier(source: source, details: details))
    }
}

private extension NodeBootstrapState {
    // A restored identity is an intermediate startup state, not a membership failure.
    func isPreparingNetwork(connectivity: ActiveNetworkConnectivity) -> Bool {
        guard connectivity != .failed && connectivity != .localNetworkDenied else { return false }
        switch self {
        case .starting, .creatingNetwork, .joiningNetwork, .identityReady, .securing:
            return true
        case .needsConfiguration, .ready, .failed:
            return false
        }
    }
}

private extension ActiveNetworkConnectivity {
    var networkTintColor: Color {
        switch self {
        case .reconnecting, .discoveringPeers:
            return .blue
        case .readyNoPeers, .connected:
            return .green
        case .inactive:
            return .secondary
        case .failed, .localNetworkDenied:
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
        networkTintColor
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
            return "1 Device Online"
        case .connected(let peerCount):
            return "\(peerCount + 1) Devices Online"
        case .localNetworkDenied:
            return "Local Network Permission Required"
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
        case .localNetworkDenied:
            return "Local Network Permission Required"
        case .failed:
            return "Unavailable"
        }
    }


}

private struct MacNetworkStatusIcon: View {
    let connectivity: ActiveNetworkConnectivity
    var systemImage = "network"

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(connectivity.networkForegroundStyle)
            .traceNetworkIndicator(
                "mac-network-icon",
                details: "color=\(connectivity.networkTintColor) connectivity=\(connectivity) symbol=\(systemImage)"
            )
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
            "1 Device Online"
        case .connected(let peerCount):
            "\(peerCount + 1) Devices Online"
        case .localNetworkDenied:
            "Enable Local Network permission for Beakr in Settings."
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
    let flagColor: MessageFlagColor?

    init(
        sender: String,
        subject: String,
        preview: String,
        receivedAt: Date,
        isRead: Bool,
        isFlagged: Bool,
        flagColor: MessageFlagColor? = nil
    ) {
        self.sender = sender
        self.subject = subject
        self.preview = preview
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.flagColor = flagColor
    }

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
                            .foregroundStyle((flagColor ?? .orange).swiftUIColor)
                            .accessibilityLabel("\((flagColor ?? .orange).title) flag")
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
    let isFlagged: Bool
    let flagColor: MessageFlagColor?

    init(
        recipient: String,
        messageBody: String,
        state: MessageDeliveryState,
        deliveredAt: Date?,
        openedAt: Date?,
        isFlagged: Bool = false,
        flagColor: MessageFlagColor? = nil
    ) {
        self.recipient = recipient
        self.messageBody = messageBody
        self.state = state
        self.deliveredAt = deliveredAt
        self.openedAt = openedAt
        self.isFlagged = isFlagged
        self.flagColor = flagColor
    }

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
                    if isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle((flagColor ?? .orange).swiftUIColor)
                            .accessibilityLabel("\((flagColor ?? .orange).title) flag")
                    }
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

private struct ActiveMessagingIndicator: View {
    let health: MessagingHealth
    let message: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "bubble.left.fill")
            if health == .degraded || health == .blocked {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
            }
        }
        .foregroundStyle(health.color)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .help(message)
    }
}

private extension MessagingHealth {
    var color: Color {
        switch self {
        case .off: .secondary
        case .healthy: .green
        case .waiting, .degraded: .orange
        case .blocked: .red
        }
    }
}

private struct NetworkStatusInformationView: View {
#if os(macOS)
    @Environment(\.dismiss) private var dismiss
#endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("Active for Messaging", systemImage: "bubble.left.fill")
                        .foregroundStyle(.blue)
                    Text("This device uses one network at a time for messaging. Choose Use for Messaging to change it.")
                        .foregroundStyle(.secondary)
#if os(macOS)
                    Text("Authority hosting is independent of messaging. This Mac can run authorities for several networks. The people-and-key icon beside a network name is blue when hosting is on, gray when off, orange while changing, and red if hosting failed. Use the network’s context menu to start or stop hosting.")
                        .foregroundStyle(.secondary)
#endif
                    Text("The leading network icon shows messaging connectivity. A pulsing icon means that Beakr'Net is still working on the connection.")
                        .foregroundStyle(.secondary)

                    NetworkStatusInformationRow(
                        color: .secondary,
                        title: "Gray",
                        description: "The network is not selected for messaging on this device."
                    )
                    NetworkStatusInformationRow(
                        color: .blue,
                        title: "Blue",
                        description: "The network is starting, reconnecting, or looking for devices."
                    )
                    NetworkStatusInformationRow(
                        color: .green,
                        title: "Green",
                        description: "The network is active and operational on this device, even when no other devices are online. Device counts show peer presence separately."
                    )
                    NetworkStatusInformationRow(
                        color: .red,
                        title: "Red",
                        description: "The selected network is unavailable, failed to connect, or needs Local Network permission. Open Network Parameters for details or to refresh it."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Network Services and Status")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
#if os(macOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
#endif
        }
#if os(macOS)
        .frame(width: 460, height: 390)
#endif
    }
}

private struct NetworkStatusInformationRow: View {
    let color: Color
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if os(iOS)
private struct IOSNetworkInstanceRoute: Identifiable {
    let id: NetworkProfileID
}

private struct IOSMailRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: MessageComposerModel
    let bootstrap: NodeBootstrapModel

    @State private var sharedStatusMember: IOSMemberDetailRoute?
    @State private var showingMessagingHealth = false
    @State private var showingManagement = false
    @State private var scannerSettingsReturnRoute: InvitationScannerReturnRoute?
    @State private var showingNetworkRemoval = false
    @State private var networkInstanceRoute: IOSNetworkInstanceRoute?
    @State private var confirmingHistoryDeletion = false
    @State private var confirmingQueuedDeletion = false
    @State private var isCommunicationIndicatorActive = false
    @State private var appleNetworkSnapshot = AppleNetworkSnapshot.unknown
    @State private var navigationPath = NavigationPath()

    private var networkSessions: [NetworkSession] {
        bootstrap.networkSessions.filter(\.isDisplayable)
    }

    private var networks: [NetworkSummary] {
        bootstrap.networks.filter { summary in networkSessions.contains { $0.id == summary.id } }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            IOSMailboxListView(
                isNavigationRoot: navigationPath.isEmpty,
                networks: networks,
                networkSessions: networkSessions,
                savedMemberships: bootstrap.savedMemberships,
                archivedContexts: bootstrap.archivedContexts,
                incomingCount: model.incomingMessages.filter { !model.trashedMessageIDs.contains($0.id) }.count,
                outgoingCount: model.outgoingMessages.filter {
                    !model.trashedMessageIDs.contains($0.id) && Mailbox.outbox.includes($0)
                }.count,
                sentCount: model.outgoingMessages.filter {
                    !model.trashedMessageIDs.contains($0.id) && Mailbox.sentItems.includes($0)
                }.count,
                trashCount: model.trashedMessageIDs.count,
                localDeviceName: bootstrap.deviceDisplayName,
                localDeviceID: bootstrap.nodeID,
                networkMembers: bootstrap.networkMembers,
                onlineMemberIDs: bootstrap.onlineMemberIDs,
                storedIncomingMessages: bootstrap.storedIncomingMessages,
                storedMailboxMetadata: bootstrap.storedMailboxMetadata,
                appleNetworkSnapshot: appleNetworkSnapshot,
                bootstrapState: bootstrap.state,
                refresh: refreshNetwork,
                switchNetwork: switchNetwork,
                showMessagingHealth: { showingMessagingHealth = true },
                showNetworkDetails: showNetworkDetails,
                showSharedStatus: { sharedStatusMember = $0 },
                deleteNetwork: bootstrap.deleteOwnedNetwork,
                forgetNetwork: { networkID, dataDisposition in
                    await bootstrap.forgetJoinedNetwork(
                        networkID,
                        dataDisposition: dataDisposition
                    )
                },
                deleteArchivedContext: bootstrap.deleteArchivedContext
            )
            .navigationDestination(for: IOSMemberDetailRoute.self) { member in
                if member.isLocalDevice {
                    IOSDeviceSettingsView(bootstrap: bootstrap, member: member)
                } else {
                    IOSMemberDetailView(member: member, bootstrap: bootstrap)
                }
            }
            .navigationDestination(for: MailboxSelection.self) { selection in
                if let contextID = selection.contextID,
                   let context = bootstrap.archivedContexts.first(where: { $0.id == contextID }) {
                    ArchivedContextMailboxView(
                        contextID: context.id,
                        contextName: context.displayName,
                        archiveReason: context.archiveReason,
                        mailbox: selection.mailbox,
                        incomingMessages: bootstrap.archivedIncomingMessages[contextID] ?? [],
                        mailboxMetadata: bootstrap.archivedMailboxMetadata[contextID] ?? .empty,
                        deleteContext: bootstrap.deleteArchivedContext
                    )
                } else if let networkID = selection.networkID {
                    let isActiveNetwork = networks.contains {
                        $0.id == networkID && $0.isActive
                    }
                    IOSMailboxMessageListView(
                        selection: selection,
                        networkName: networks.first(where: { $0.id == networkID })?.displayName ?? "Network",
                        networkConnectivity: isActiveNetwork
                            ? bootstrap.activeNetworkConnectivity
                            : .inactive,
                        appleNetworkSnapshot: appleNetworkSnapshot,
                        model: model,
                        isActiveNetwork: isActiveNetwork,
                        storedIncomingMessages: bootstrap.storedIncomingMessages[networkID] ?? [],
                        storedMailboxMetadata: bootstrap.storedMailboxMetadata[networkID] ?? .empty,
                        makeActive: { switchNetwork(networkID) },
                        refresh: refreshNetwork
                    )
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        IOSNetworkSwitcherMenu(
                            networks: networks,
                            connectivity: bootstrap.activeNetworkConnectivity,
                            statusTitle: bootstrap.activeNetworkStatusTitle,
                            requiresAttention: networks.contains(where: \.isActive) && bootstrap.state != .ready
                                && !bootstrap.state.isPreparingNetwork(connectivity: bootstrap.activeNetworkConnectivity),
                            isStarting: bootstrap.state.isPreparingNetwork(connectivity: bootstrap.activeNetworkConnectivity),
                            switchNetwork: switchNetwork,
                            manageNetworks: {
                                showingManagement = true
                            },
                            removeNetworks: {
                                showingNetworkRemoval = true
                            }
                        )
                        .traceNetworkIndicator(
                            "ios-toolbar-inputs",
                            details: "bootstrap=\(bootstrap.state) connectivity=\(bootstrap.activeNetworkConnectivity) networkCount=\(networks.count) hasActiveNetwork=\(networks.contains(where: \.isActive)) starting=\(bootstrap.state.isPreparingNetwork(connectivity: bootstrap.activeNetworkConnectivity)) requiresAttention=\(networks.contains(where: \.isActive) && bootstrap.state != .ready && !bootstrap.state.isPreparingNetwork(connectivity: bootstrap.activeNetworkConnectivity)) rule=attention-excludes-startup"
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
            }
        }
        .sheet(item: $sharedStatusMember) { member in
            IOSMemberSharedStatusSheet(member: member, bootstrap: bootstrap)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingMessagingHealth) {
            NavigationStack {
                MessagingServicesView(bootstrap: bootstrap)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingMessagingHealth = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingManagement) {
            IOSBeakrManagementView(
                model: model,
                bootstrap: bootstrap,
                initialNetworkID: nil,
                joinCompleted: returnToRootAfterJoin,
                dismiss: { showingManagement = false }
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingNetworkRemoval) {
            IOSRemoveNetworksView(
                networks: networks.filter { !$0.isHostingAuthority },
                connectivity: bootstrap.activeNetworkConnectivity,
                removeAndKeepData: { networkID in
                    await bootstrap.forgetJoinedNetwork(
                        networkID,
                        dataDisposition: .keepLocalData
                    )
                },
                removeAndDeleteData: { networkID in
                    await bootstrap.forgetJoinedNetwork(
                        networkID,
                        dataDisposition: .deleteLocalData
                    )
                }
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $networkInstanceRoute) { route in
            IOSBeakrManagementView(
                model: model,
                bootstrap: bootstrap,
                initialNetworkID: route.id,
                joinCompleted: returnToRootAfterJoin,
                dismiss: { networkInstanceRoute = nil }
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $scannerSettingsReturnRoute) { route in
            IOSBeakrManagementView(
                model: model,
                bootstrap: bootstrap,
                initialNetworkID: route.initialNetworkID.map { NetworkProfileID(rawValue: $0) },
                joinCompleted: returnToRootAfterJoin,
                dismiss: { scannerSettingsReturnRoute = nil },
                scannerReturnRoute: route
            )
            .presentationDragIndicator(.visible)
        }
        .task {
            scannerSettingsReturnRoute = InvitationScannerReturnRoute.take()
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
        .task(id: "\(scenePhase)-\(WiFiNameAccess.shared.revision)") {
            guard scenePhase == .active else { return }
            WiFiNameAccess.shared.refreshAuthorization()
            for await path in CurrentInternetRouteProbe.updates() {
                let snapshot = await AppleNetworkSnapshot.capture(path: path)
                guard !Task.isCancelled else { return }
                appleNetworkSnapshot = snapshot
            }
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
                get: { bootstrap.standaloneNetworkJoinAlert },
                set: { bootstrap.standaloneNetworkJoinAlert = $0 }
            ),
            confirmCollision: { Task { await bootstrap.confirmCollidingNetworkJoin() } },
            confirmReattachment: { Task { await bootstrap.confirmContextReattachment() } }
        )
    }

    private func switchNetwork(_ networkID: NetworkProfileID) {
        guard !networks.contains(where: { $0.id == networkID && $0.isActive }) else { return }
        navigationPath = NavigationPath()
        Task { await bootstrap.switchNetwork(to: networkID) }
    }

    private func returnToRootAfterJoin() {
        navigationPath = NavigationPath()
        showingManagement = false
        networkInstanceRoute = nil
        scannerSettingsReturnRoute = nil
    }

    private func showNetworkDetails(_ networkID: NetworkProfileID) {
        networkInstanceRoute = IOSNetworkInstanceRoute(id: networkID)
    }

    private func refreshNetwork() async {
        await bootstrap.refreshNetworkCredentials()
        guard !Task.isCancelled else { return }
        appleNetworkSnapshot = await AppleNetworkSnapshot.capture()
    }
}

private struct IOSNetworkSwitcherMenu: View {
    @State private var isPresented = false

    let networks: [NetworkSummary]
    let connectivity: ActiveNetworkConnectivity
    let statusTitle: String
    let requiresAttention: Bool
    let isStarting: Bool
    let switchNetwork: (NetworkProfileID) -> Void
    let manageNetworks: () -> Void
    let removeNetworks: () -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            NetworkStatusIcon(
                connectivity: connectivity,
                hasNetworks: !networks.isEmpty,
                requiresAttention: requiresAttention,
                isStarting: isStarting
            )
        }
        .accessibilityLabel("Switch Network")
        .accessibilityValue(isStarting ? "Connecting" : (requiresAttention ? "Network requires attention." : statusTitle))
        .popover(isPresented: $isPresented) {
            VStack(spacing: 0) {
                ForEach(networks) { network in
                    Button {
                        isPresented = false
                        guard !network.isActive else { return }
                        switchNetwork(network.id)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: network.isActive ? "checkmark.circle.fill" : "circle")
                                .frame(width: 24)
                            Text(network.displayName)
                            Spacer(minLength: 20)
                        }
                        .font(.title3)
                        .foregroundStyle(networkStyle(for: network))
                        .contentShape(Rectangle())
                        .padding(.horizontal, 20)
                        .frame(minHeight: 52)
                    }
                    .buttonStyle(.plain)
                }

                if !networks.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)
                }

                Button {
                    isPresented = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        manageNetworks()
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(connectivity == .localNetworkDenied ? Color.red : Color.primary)
                            .frame(width: 24)
                        Text("Settings…")
                        Spacer(minLength: 20)
                    }
                    .font(.title3)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
                }
                .buttonStyle(.plain)

                if networks.contains(where: { !$0.isHostingAuthority }) {
                    Button(role: .destructive) {
                        isPresented = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            removeNetworks()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "minus.circle.fill")
                                .frame(width: 24)
                            Text("Remove Networks…")
                            Spacer(minLength: 20)
                        }
                        .font(.title3)
                        .foregroundStyle(.red)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 20)
                        .frame(minHeight: 52)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 280)
            .padding(.vertical, 8)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func networkStyle(for network: NetworkSummary) -> AnyShapeStyle {
        network.isActive
            ? connectivity.networkForegroundStyle
            : AnyShapeStyle(Color.secondary)
    }
}

private struct NetworkStatusIcon: View {
    let connectivity: ActiveNetworkConnectivity
    let hasNetworks: Bool
    let requiresAttention: Bool
    let isStarting: Bool

    @ViewBuilder
    var body: some View {
        if isStarting {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating.speed(0.7), isActive: true)
                .traceNetworkIndicator(
                    "ios-network-gear",
                    details: "color=secondary reason=startup pulsing=true hasNetworks=\(hasNetworks) requiresAttention=\(requiresAttention) connectivity=\(connectivity)"
                )
        } else if !hasNetworks || requiresAttention {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(.red)
                .traceNetworkIndicator(
                    "ios-network-gear",
                    details: "color=red reason=\(!hasNetworks ? "noNetworks" : "requiresAttention") hasNetworks=\(hasNetworks) requiresAttention=\(requiresAttention) connectivity=\(connectivity)"
                )
        } else if connectivity.isTransitioning {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(connectivity == .reconnecting ? Color.secondary : connectivity.statusColor)
                .symbolEffect(.pulse, options: .repeating.speed(0.7), isActive: true)
                .traceNetworkIndicator(
                    "ios-network-gear",
                    details: "color=\(connectivity == .reconnecting ? Color.secondary : connectivity.statusColor) reason=connectivity pulsing=true hasNetworks=\(hasNetworks) requiresAttention=\(requiresAttention) connectivity=\(connectivity)"
                )
        } else {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(connectivity.statusColor)
                .traceNetworkIndicator(
                    "ios-network-gear",
                    details: "color=\(connectivity.statusColor) reason=connectivity pulsing=false hasNetworks=\(hasNetworks) requiresAttention=\(requiresAttention) connectivity=\(connectivity)"
                )
        }
    }
}

private struct IOSMailboxListView: View {
    @Environment(\.scenePhase) private var scenePhase
    let isNavigationRoot: Bool
    let networks: [NetworkSummary]
    let networkSessions: [NetworkSession]
    let savedMemberships: [NetworkProfileID: SavedNetworkMembership]
    let archivedContexts: [ContextSummary]
    let incomingCount: Int
    let outgoingCount: Int
    let sentCount: Int
    let trashCount: Int
    let localDeviceName: String
    let localDeviceID: UUID?
    let networkMembers: [NetworkMemberSummary]
    let onlineMemberIDs: Set<UUID>
    let storedIncomingMessages: [NetworkProfileID: [IncomingMessage]]
    let storedMailboxMetadata: [NetworkProfileID: ContextMailboxMetadata]
    let appleNetworkSnapshot: AppleNetworkSnapshot
    let bootstrapState: NodeBootstrapState
    let refresh: () async -> Void
    let switchNetwork: (NetworkProfileID) -> Void
    let showMessagingHealth: () -> Void
    let showNetworkDetails: (NetworkProfileID) -> Void
    let showSharedStatus: (IOSMemberDetailRoute) -> Void
    let deleteNetwork: (NetworkProfileID) async -> Void
    let forgetNetwork: (NetworkProfileID, ForgottenNetworkDataDisposition) async -> Void
    let deleteArchivedContext: (ContextID) async -> Void
    @State private var refreshPhase = NetworkRefreshPhase.idle
    @State private var hasCompletedManualRefresh = false
    @State private var refreshResultDismissTask: Task<Void, Never>?
    @State private var pullStage = NetworkPullStage.hidden
    @State private var expandedNetworkIDs: Set<NetworkProfileID> = []
    @State private var expandedMailboxIDs: Set<NetworkProfileID> = []
    @State private var expandedMemberIDs: Set<NetworkProfileID> = []
    @State private var previousActiveNetworkID: NetworkProfileID?
    @State private var hasInitializedExpansion = false
    @State private var contextPendingDeletion: ContextSummary?
    @State private var networkPendingRemoval: NetworkSummary?
    @State private var networkPendingForget: NetworkSummary?
    @State private var isShowingNetworkStatusInformation = false
    @State private var startupLoadingTimedOut = false

    private var activeNetworkConnectivity: ActiveNetworkConnectivity {
        networkSessions.first(where: \.isSelected)?.connectivity ?? .inactive
    }

    private var orderedNetworks: [NetworkSummary] {
        guard let activeIndex = networks.firstIndex(where: \.isActive) else {
            return networks
        }

        var orderedNetworks = networks
        let activeNetwork = orderedNetworks.remove(at: activeIndex)
        orderedNetworks.insert(activeNetwork, at: 0)
        return orderedNetworks
    }

    private var productName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Beakr"
    }

    private var emptyNetworkStatus: LocalizedStringResource {
        if pullStage != .hidden {
            return "Pull to Refresh"
        }
        if bootstrapState == .starting && !startupLoadingTimedOut {
            return "Checking Networks…"
        }
        return "No Networks"
    }

    private var emptyNetworkDescription: LocalizedStringResource {
        if pullStage != .hidden {
            return "Keep pulling until the refresh indicator appears."
        }
        return "Use the red Settings icon to create or join a network, or pull to refresh."
    }

    private var refreshStatus: LocalizedStringResource? {
        if refreshPhase == .refreshing || refreshPhase == .settling {
            return "Refreshing Networks…"
        }

        if networks.isEmpty && archivedContexts.isEmpty {
            return emptyNetworkStatus
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

    private func displayedIncomingCount(for network: NetworkSummary) -> Int {
        guard !network.isActive else { return incomingCount }
        let trashedIDs = storedMailboxMetadata[network.id]?.trashedMessageIDs ?? []
        return (storedIncomingMessages[network.id] ?? []).count { !trashedIDs.contains($0.id) }
    }

    private func displayedOutgoingCount(for network: NetworkSummary) -> Int {
        guard !network.isActive else { return outgoingCount }
        let metadata = storedMailboxMetadata[network.id]
        return (metadata?.outgoingMessages ?? []).count {
            !(metadata?.trashedMessageIDs.contains($0.id) ?? false) && Mailbox.outbox.includes($0)
        }
    }

    private func displayedSentCount(for network: NetworkSummary) -> Int {
        guard !network.isActive else { return sentCount }
        let metadata = storedMailboxMetadata[network.id]
        return (metadata?.outgoingMessages ?? []).count {
            !(metadata?.trashedMessageIDs.contains($0.id) ?? false) && Mailbox.sentItems.includes($0)
        }
    }

    private func displayedTrashCount(for network: NetworkSummary) -> Int {
        network.isActive ? trashCount : storedMailboxMetadata[network.id]?.trashedMessageIDs.count ?? 0
    }

    private func networkOverviewSection(_ network: NetworkSummary) -> some View {
        IOSNetworkOverviewSection(
            network: network,
            incomingCount: displayedIncomingCount(for: network),
            outgoingCount: displayedOutgoingCount(for: network),
            sentCount: displayedSentCount(for: network),
            trashCount: displayedTrashCount(for: network),
            localDeviceName: localDeviceName,
            localDeviceID: networkSessions.first { $0.id == network.id }?.profile.localNodeID.rawValue,
            localDeviceIsMember: !network.isActive || bootstrapState == .ready,
            isStarting: network.isActive && bootstrapState.isPreparingNetwork(connectivity: activeNetworkConnectivity),
            members: network.isActive ? networkMembers : savedMemberships[network.id]?.members ?? [],
            membershipIssue: savedMemberships[network.id]?.state == .saved
                ? nil : (savedMemberships[network.id] ?? .unavailable).notice,
            onlineMemberIDs: network.isActive ? onlineMemberIDs : [],
            connectivity: activeNetworkConnectivity,
            appleNetworkSnapshot: appleNetworkSnapshot,
            showDetails: { showNetworkDetails(network.id) },
            showMessagingHealth: showMessagingHealth,
            showSharedStatus: showSharedStatus,
            makeActive: { switchNetwork(network.id) },
            requestRemoval: {
                if network.isHostingAuthority {
                    networkPendingRemoval = network
                } else {
                    networkPendingForget = network
                }
            },
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

    @State private var listPresentationID = UUID()

    var body: some View {
        mailboxList
            .onChange(of: isNavigationRoot) { wasRoot, isRoot in
                // Recreate only the List's presentation to restore its native top
                // inset. Expansion and refresh state live in this parent view.
                // Peer updates never reset the presentation or scroll position.
                if !wasRoot && isRoot {
                    listPresentationID = UUID()
                }
            }
    }

    private var mailboxList: some View {
        List {
            MailboxPageTitleRow(
                title: LocalizedStringKey(productName),
                subtitle: "Networks",
                status: refreshStatus,
                statusDate: hasCompletedManualRefresh ? appleNetworkSnapshot.checkedAt : nil,
                showSubtitleInformation: { isShowingNetworkStatusInformation = true }
            )
            .padding(.bottom, (refreshStatus != nil || hasCompletedManualRefresh) ? 4 : -4)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))

            ForEach(orderedNetworks) { network in
                networkOverviewSection(network)
            }

            if !archivedContexts.isEmpty {
                Section("Preserved Contexts") {
                    ForEach(archivedContexts) { context in
                        DisclosureGroup {
                            if context.archiveReason == .membershipRevoked {
                                RevokedContextExplanation()
                            }
                            NavigationLink(value: MailboxSelection(contextID: context.id, mailbox: .inbox)) {
                                ArchivedContextRow(mailbox: .inbox)
                            }

                            NavigationLink(value: MailboxSelection(contextID: context.id, mailbox: .outbox)) {
                                ArchivedContextRow(mailbox: .outbox)
                            }

                            NavigationLink(value: MailboxSelection(contextID: context.id, mailbox: .sentItems)) {
                                ArchivedContextRow(mailbox: .sentItems)
                            }

                            NavigationLink(value: MailboxSelection(contextID: context.id, mailbox: .trash)) {
                                ArchivedContextRow(mailbox: .trash)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(context.displayName, systemImage: "archivebox")
                                if context.archiveReason == .membershipRevoked {
                                    Text("Access Revoked")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
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
        .id(listPresentationID)
        .refreshable { await performNetworkRefresh() }
        .sheet(isPresented: $isShowingNetworkStatusInformation) {
            NetworkStatusInformationView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $networkPendingForget) { network in
            IOSForgetNetworkSheet(
                network: network,
                connectivity: activeNetworkConnectivity,
                forgetAndKeepData: {
                    networkPendingForget = nil
                    Task { await forgetNetwork(network.id, .keepLocalData) }
                },
                forgetAndDeleteData: {
                    networkPendingForget = nil
                    Task { await forgetNetwork(network.id, .deleteLocalData) }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete Network?",
            isPresented: Binding(
                get: { networkPendingRemoval != nil },
                set: { if !$0 { networkPendingRemoval = nil } }
            ),
            presenting: networkPendingRemoval
        ) { network in
            Button("Delete \(network.displayName)", role: .destructive) {
                networkPendingRemoval = nil
                Task { await deleteNetwork(network.id) }
            }
            Button("Keep Network", role: .cancel) {}
        } message: { network in
            Text("This permanently removes \(network.displayName), its management credentials, and its local data.")
        }
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
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelNetworkRefreshPresentation()
        }
        .task(id: bootstrapState) {
            startupLoadingTimedOut = false
            guard bootstrapState == .starting else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, bootstrapState == .starting else { return }
            startupLoadingTimedOut = true
        }
        .overlay {
            if networks.isEmpty && archivedContexts.isEmpty {
                if refreshPhase == .refreshing || refreshPhase == .settling {
                    EmptyView()
                } else if bootstrapState == .starting && !startupLoadingTimedOut && pullStage == .hidden {
                    ProgressView("Checking Networks…")
                        .allowsHitTesting(false)
                } else {
                    ContentUnavailableView {
                        Label {
                            Text(emptyNetworkStatus)
                        } icon: {
                            Image(systemName: "network.slash")
                        }
                    } description: {
                        Text(emptyNetworkDescription)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func performNetworkRefresh() async {
        guard refreshPhase != .refreshing else { return }
        refreshResultDismissTask?.cancel()
        pullStage = .hidden
        refreshPhase = .refreshing
        let refreshStartedAt = ContinuousClock.now
        await refresh()
        let minimumRefreshDuration = Duration.seconds(1)
        let elapsedRefreshDuration = ContinuousClock.now - refreshStartedAt
        if elapsedRefreshDuration < minimumRefreshDuration {
            try? await Task.sleep(for: minimumRefreshDuration - elapsedRefreshDuration)
        }
        guard !Task.isCancelled else { return }
        refreshPhase = .settling
        refreshResultDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            hasCompletedManualRefresh = true
            refreshPhase = .finished
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

private struct IOSMemberDetailRoute: Hashable, Identifiable {
    var id: String { "\(profileID.rawValue)-\(deviceID?.uuidString ?? credentialID?.uuidString ?? "local")" }
    let profileID: NetworkProfileID
    let credentialID: UUID?
    let networkName: String
    let deviceID: UUID?
    let displayName: String
    let isLocalDevice: Bool
    let isOnline: Bool
    let isActiveNetwork: Bool
}

private struct IOSMemberSharedStatusSheet: View {
    let member: IOSMemberDetailRoute
    let bootstrap: NodeBootstrapModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Shared Status").font(.headline)
                    Text(member.displayName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Form {
                if let peerID = member.deviceID {
                    SharedStatusSection(
                        profileID: member.profileID, peerID: peerID, peerName: member.displayName,
                        isOnline: bootstrap.profileID == member.profileID.rawValue && bootstrap.memberStatus(
                            profileID: member.profileID, nodeID: peerID,
                            credentialID: member.credentialID, isLocalDevice: false
                        ) == .online,
                        bootstrap: bootstrap, showsHeader: false
                    )
                    .id(member.id)
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
        }
    }
}

private struct IOSMemberDetailView: View {
    let member: IOSMemberDetailRoute
    let bootstrap: NodeBootstrapModel

    private var currentPeer: NetworkMemberSummary? {
        guard status == .online, bootstrap.profileID == member.profileID.rawValue,
              let id = member.deviceID else { return nil }
        return bootstrap.networkMembers.first { $0.id == id }
    }

    private var status: NetworkMemberStatus {
        bootstrap.memberStatus(
            profileID: member.profileID,
            nodeID: member.deviceID,
            credentialID: member.credentialID,
            isLocalDevice: member.isLocalDevice
        )
    }

    private var statusColor: Color {
        switch status {
        case .online: .green
        case .offline, .unknown: .secondary
        case .revoked: .red
        }
    }

    var body: some View {
        Form {
            Section("Device") {
                if !member.isLocalDevice {
                    LabeledContent("Reported IPv4", value: currentPeer?.deviceIPAddress ?? "--")
                    LabeledContent("Connection IP") {
                        Text(currentPeer?.connectionIPAddress ?? "--")
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Name", value: currentPeer?.displayName ?? member.displayName)

                LabeledContent("Node ID") {
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
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)

                        Text(status.title)
                            .foregroundStyle(statusColor)
                    }
                }
                .padding(.vertical, -4)
            }
            .listSectionSpacing(20)

            if let peerID = member.deviceID {
                SharedStatusSection(profileID: member.profileID, peerID: peerID, peerName: currentPeer?.displayName ?? member.displayName,
                                    isOnline: status == .online && bootstrap.profileID == member.profileID.rawValue,
                                    bootstrap: bootstrap)
                    .id("\(member.profileID.rawValue)-\(peerID)")
            }

            Section("Network Membership") {
                HStack(alignment: .top) {
                    Text("Beakr'Net")

                    Spacer(minLength: 16)

                    Text(member.networkName)
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .navigationTitle(currentPeer?.displayName ?? member.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Aligns the disclosure control with the network name instead of the
/// middle of its three-line label. Nested groups retain their system style.
private struct NetworkDisclosureGroupStyle<MenuContent: View>: DisclosureGroupStyle {
    private let menuContent: () -> MenuContent

    init(@ViewBuilder menuContent: @escaping () -> MenuContent) {
        self.menuContent = menuContent
    }

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation {
                configuration.isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.body.weight(.semibold))
                    .imageScale(.small)
                    .fixedSize()
                    .foregroundStyle(.primary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))
        // Attach actions to the interactive row, not inside its button label.
        .contextMenu { menuContent() }

        if configuration.isExpanded {
            configuration.content
                .disclosureGroupStyle(.automatic)
                .padding(.leading, 20)
        }
    }
}

private struct IOSNetworkOverviewSection: View {
    let network: NetworkSummary
    let incomingCount: Int
    let outgoingCount: Int
    let sentCount: Int
    let trashCount: Int
    let localDeviceName: String
    let localDeviceID: UUID?
    let localDeviceIsMember: Bool
    let isStarting: Bool
    let members: [NetworkMemberSummary]
    let membershipIssue: LocalizedStringResource?
    let onlineMemberIDs: Set<UUID>
    let connectivity: ActiveNetworkConnectivity
    let appleNetworkSnapshot: AppleNetworkSnapshot
    let showDetails: () -> Void
    let showMessagingHealth: () -> Void
    let showSharedStatus: (IOSMemberDetailRoute) -> Void
    let makeActive: () -> Void
    let requestRemoval: () -> Void
    @Binding var networkIsExpanded: Bool
    @Binding var mailboxesAreExpanded: Bool
    @Binding var membersAreExpanded: Bool
    @State private var unavailableActivationFeedbackSequence = 0
    @State private var showingConnectionInfo = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $networkIsExpanded) {
                DisclosureGroup(isExpanded: $membersAreExpanded) {
                    if localDeviceIsMember {
                        NavigationLink(value: IOSMemberDetailRoute(
                            profileID: network.id,
                            credentialID: nil,
                            networkName: network.displayName,
                            deviceID: localDeviceID,
                            displayName: localDeviceName,
                            isLocalDevice: true,
                            isOnline: network.isActive && !isStarting && connectivity.isLocalDeviceOnline,
                            isActiveNetwork: network.isActive
                        )) {
                            IOSNetworkMemberRow(
                                displayName: localDeviceName,
                                isLocalDevice: true,
                                isOnline: network.isActive && !isStarting && connectivity.isLocalDeviceOnline,
                                presenceKnown: network.isActive,
                                deviceIPAddress: appleNetworkSnapshot.localIPv4Address
                            )
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .contextMenu {
                            Button("Shared Status", systemImage: "info.circle") {}
                                .disabled(true)
                        }
                    }

                    ForEach(members) { member in
                        NavigationLink(value: IOSMemberDetailRoute(
                            profileID: network.id,
                            credentialID: member.credentialID,
                            networkName: network.displayName,
                            deviceID: member.id,
                            displayName: member.displayName,
                            isLocalDevice: false,
                            isOnline: onlineMemberIDs.contains(member.id),
                            isActiveNetwork: network.isActive
                        )) {
                            IOSNetworkMemberRow(
                                displayName: member.displayName,
                                isLocalDevice: false,
                                isOnline: onlineMemberIDs.contains(member.id),
                                presenceKnown: network.isActive,
                                deviceIPAddress: onlineMemberIDs.contains(member.id) ? member.deviceIPAddress : nil
                            )
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .contextMenu {
                            Button("Shared Status", systemImage: "info.circle") {
                                showSharedStatus(IOSMemberDetailRoute(
                                    profileID: network.id,
                                    credentialID: member.credentialID,
                                    networkName: network.displayName,
                                    deviceID: member.id,
                                    displayName: member.displayName,
                                    isLocalDevice: false,
                                    isOnline: onlineMemberIDs.contains(member.id),
                                    isActiveNetwork: network.isActive
                                ))
                            }
                        }
                    }

                    if !localDeviceIsMember && !isStarting {
                        Text("Network setup needs attention. Open Network Parameters and check Last Error for details.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if !network.isActive, let membershipIssue {
                        Text(membershipIssue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if network.isActive && members.isEmpty {
                        Text("No other members have been discovered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Members", systemImage: "shareplay")
                }

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

                    NavigationLink(value: MailboxSelection(networkID: network.id, mailbox: .sentItems)) {
                        HStack {
                            Image(systemName: "paperplane")
                            Text("Sent Items")
                        }
                        .padding(.vertical, -7)
                        .badge(sentCount)
                    }

                    NavigationLink(value: MailboxSelection(networkID: network.id, mailbox: .trash)) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Trash")
                        }
                        .padding(.vertical, -7)
                        .badge(trashCount)
                    }
                } label: {
                    Label("Mailboxes", systemImage: "tray.2")
                }

            } label: {
                HStack(alignment: .top, spacing: 8) {
                    NetworkMailboxHeader(
                        name: network.displayName,
                        isActive: network.isActive,
                        connectivity: connectivity,
                        requiresAttention: !localDeviceIsMember && !isStarting,
                        isStarting: isStarting,
                        appleNetworkSnapshot: appleNetworkSnapshot,
                        topSpacingAdjustment: 0,
                        credentialStatus: network.credentialStatus
                    )
                    if network.isActive {
                        Button(action: showMessagingHealth) {
                            ActiveMessagingIndicator(health: network.messagingHealth, message: network.messagingHealthMessage)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(.vertical, -5)
                .contentShape(Rectangle())

            }
        }
        .disclosureGroupStyle(NetworkDisclosureGroupStyle {
            Button("Connection Info", systemImage: "info.circle") {
                showingConnectionInfo = true
            }
            Button("View Parameters", systemImage: "slider.horizontal.3", action: showDetails)
            Divider()
            Button("Use for Messaging", systemImage: "bubble.left.fill", action: requestMakeActive)
                .disabled(network.isActive)
            Divider()
            Button(
                network.isHostingAuthority ? "Delete Network…" : "Forget Network…",
                systemImage: network.isHostingAuthority
                    ? "trash"
                    : "rectangle.portrait.and.arrow.right",
                role: .destructive,
                action: requestRemoval
            )
        })
        .listSectionSpacing(22)
        .sensoryFeedback(.warning, trigger: unavailableActivationFeedbackSequence)
        .sheet(isPresented: $showingConnectionInfo) {
            NavigationStack {
                Form {
                    Section("This Device’s Connection") {
                        Text(appleNetworkSnapshot.connectionDetail)
                    }
                    Section("Beakr Connectivity") {
                        Text(connectionGuidance)
                    }
                    WiFiNamePermissionSection()
                }
                .navigationTitle("Connection Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingConnectionInfo = false }
                    }
                }
            }
        }
    }

    private var connectionGuidance: LocalizedStringResource {
        guard network.isActive else {
            return "Choose Use for Messaging to use this network for messaging on this device."
        }
        if case .connected(let count) = connectivity {
            return "Securely connected to \(count) other devices. The IP address shown belongs to this device, not the router."
        }
        if let status = network.credentialStatus {
            return "\(status.title). Open Services → Messaging for credential details and recovery."
        }
        if connectivity == .failed {
            return "The local connection failed. Check Wi-Fi or Ethernet, then pull down to retry. Open Network Parameters for more details."
        }
        if isStarting {
            return "Beakr is restoring this device’s identity and checking its network membership before starting local discovery."
        }
        if !localDeviceIsMember {
            return "Network setup needs attention. Open Network Parameters for details."
        }
        switch connectivity {
        case .readyNoPeers:
            return "This network is operational on this device. No other devices are online. Open Beakr on another device on the same local network to connect."
        case .discoveringPeers:
            return "Open Beakr on another device on the same local network. Check that both devices can reach one another; guest Wi-Fi or router isolation may prevent discovery."
        case .reconnecting:
            return "Beakr is checking the local connection and restarting discovery."
        case .inactive:
            return "Check that Wi-Fi or Ethernet is connected, then pull down to retry."
        case .localNetworkDenied:
            return "Enable Local Network permission for Beakr in Settings."
        case .connected, .failed:
            return "Open Network Parameters for connection details."
        }
    }

    private func requestMakeActive() {
        if network.isActive {
            unavailableActivationFeedbackSequence += 1
        } else {
            makeActive()
        }
    }
}

private struct IOSNetworkMemberRow: View {
    let displayName: String
    let isLocalDevice: Bool
    let isOnline: Bool
    var presenceKnown = true
    var deviceIPAddress: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Measure one line in the name's font so icons stay centered on
            // its first line, including with Dynamic Type or wrapped names.
            ZStack {
                Text(verbatim: " ")
                    .fixedSize()
                    .hidden()
                    .frame(width: 0)
                Circle()
                    .fill(isOnline ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 9, height: 9)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                if !presenceKnown {
                    Text("UnObserved").font(.caption).foregroundStyle(.secondary)
                }
                Text(isLocalDevice
                     ? LocalizedStringResource("This Device IP: \(deviceIPAddress ?? "--")")
                     : LocalizedStringResource("Device IP: \(deviceIPAddress ?? "--")"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            ZStack {
                Text(verbatim: " ")
                    .fixedSize()
                    .hidden()
                    .frame(width: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, -7)
        .accessibilityElement(children: .combine)
        .accessibilityValue(!presenceKnown ? "UnObserved" : (isOnline ? "Online" : "Offline"))
    }
}

private struct IOSIncomingMessageDetail: View {
    let message: IncomingMessage
    let senderName: String
    let model: MessageComposerModel
    let isActiveNetwork: Bool
    @State private var showingReply = false

    private var canReply: Bool {
        isActiveNetwork && message.source.map { model.isAddressable($0) } == true
    }

    var body: some View {
        MailMessageDetail(
            heading: senderName,
            address: message.source?.uuidString,
            metadata: message.receivedAt.formatted(date: .abbreviated, time: .shortened),
            messageBody: message.body
        )
        .toolbar {
            if isActiveNetwork {
                ToolbarItem(placement: .bottomBar) {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") {
                        guard canReply else { return }
                        model.prepareReply(to: message)
                        showingReply = true
                    }
                    .disabled(!canReply)
                    .accessibilityIdentifier("replyToMessage")
                }
            }
        }
        .sheet(isPresented: $showingReply, onDismiss: model.discardDraft) {
            IOSMessageComposerView(model: model, dismiss: { showingReply = false })
        }
        .onChange(of: isActiveNetwork) { _, active in
            if !active { showingReply = false }
        }
    }
}

private struct ArchivedContextMailboxView: View {
    @Environment(\.dismiss) private var dismiss
    let contextID: ContextID
    let contextName: String
    let archiveReason: ContextArchiveReason?
    let mailbox: Mailbox
    let incomingMessages: [IncomingMessage]
    let mailboxMetadata: ContextMailboxMetadata
    let deleteContext: (ContextID) async -> Void
    @State private var confirmingDeletion = false

    private var visibleOutgoingMessages: [OutgoingMessage] {
        if mailbox == .trash {
            return mailboxMetadata.outgoingMessages.filter { mailboxMetadata.trashedMessageIDs.contains($0.id) }
        }
        return mailboxMetadata.outgoingMessages.filter {
            !mailboxMetadata.trashedMessageIDs.contains($0.id) && mailbox.includes($0)
        }
    }

    private var visibleIncomingMessages: [IncomingMessage] {
        mailbox == .trash
            ? incomingMessages.filter { mailboxMetadata.trashedMessageIDs.contains($0.id) }
            : incomingMessages.filter { !mailboxMetadata.trashedMessageIDs.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                if archiveReason == .membershipRevoked {
                    RevokedContextExplanation()
                }
                Label("Preserved Context — Read Only", systemImage: "archivebox")
                    .foregroundStyle(.secondary)
                LabeledContent("Context", value: contextName)
            } footer: {
                Text("Reconnect this Context with a new invitation to send, reply, or change its stored messages.")
            }

            switch mailbox {
            case .inbox:
                ForEach(visibleIncomingMessages) { message in
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
            case .outbox, .sentItems:
                ForEach(visibleOutgoingMessages) { message in
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
            case .trash:
                ForEach(visibleIncomingMessages) { message in
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
                ForEach(visibleOutgoingMessages) { message in
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
            if mailbox == .inbox && visibleIncomingMessages.isEmpty {
                ContentUnavailableView("No Preserved Messages", systemImage: "tray.and.arrow.down")
            } else if mailbox == .trash && visibleIncomingMessages.isEmpty && visibleOutgoingMessages.isEmpty {
                ContentUnavailableView("No Preserved Messages", systemImage: "trash")
            } else if mailbox != .inbox && mailbox != .trash && visibleOutgoingMessages.isEmpty {
                ContentUnavailableView("No Preserved Messages", systemImage: mailbox.systemImage)
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
    let isActiveNetwork: Bool
    let storedIncomingMessages: [IncomingMessage]
    let storedMailboxMetadata: ContextMailboxMetadata
    let makeActive: () -> Void
    let refresh: () async -> Void
    @State private var showingComposer = false
    @State private var inboxFilter = InboxFilter.all
    @State private var searchText = ""
    @State private var visibleIncomingMessages: [IncomingMessage] = []
    @State private var selectedIncomingMessage: IncomingMessage?
    @State private var refreshPhase = NetworkRefreshPhase.idle
    @State private var refreshResultDismissTask: Task<Void, Never>?
    @State private var pullStage = NetworkPullStage.hidden
    @State private var armedHapticSequence = 0
    @State private var presentedMessageInfo: PresentedMessageInfo?

    private var visibleOutgoingMessages: [OutgoingMessage] {
        let messages = isActiveNetwork ? model.outgoingMessages : storedMailboxMetadata.outgoingMessages
        let trashedMessageIDs = isActiveNetwork ? model.trashedMessageIDs : storedMailboxMetadata.trashedMessageIDs
        if selection.mailbox == .trash {
            return messages.filter { trashedMessageIDs.contains($0.id) }
        }
        return messages.filter {
            !trashedMessageIDs.contains($0.id) && selection.mailbox.includes($0)
        }
    }

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
                        unreadCount: sourceIncomingMessages.lazy.filter { !isRead($0.id) }.count,
                        queuedCount: 0,
                        messageCount: sourceIncomingMessages.count,
                        lastUpdated: sourceIncomingMessages.first?.receivedAt
                    )
                }

                ForEach(visibleIncomingMessages) { message in
                    incomingMessageLink(for: message)
                }
            case .outbox, .sentItems:
                Section {
                    EmptyView()
                } header: {
                    MailboxSummaryHeader(
                        networkName: networkName,
                        networkConnectivity: networkConnectivity,
                        mailbox: selection.mailbox,
                        unreadCount: 0,
                        queuedCount: selection.mailbox == .outbox
                            ? visibleOutgoingMessages.lazy.filter {
                                $0.state == .queued || $0.state == .sending
                            }.count
                            : 0,
                        messageCount: visibleOutgoingMessages.count,
                        lastUpdated: visibleOutgoingMessages.first.flatMap { $0.openedAt ?? $0.deliveredAt }
                    )
                }

                ForEach(visibleOutgoingMessages) { message in
                    NavigationLink {
                        MailMessageDetail(
                            heading: displayName(for: message.destination),
                            address: message.destination.uuidString,
                            metadata: message.state.detailTitle,
                            messageBody: message.body
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            OutgoingMailRow(
                                recipient: displayName(for: message.destination),
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
                        if isActiveNetwork {
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
                        }

                        Button("Message Info", systemImage: "info.circle") {
                            presentedMessageInfo = .outgoing(message)
                        }
                    } preview: {
                        MessageContextPreview(
                            heading: displayName(for: message.destination),
                            metadata: message.state.detailTitle,
                            subject: nil,
                            messageBody: message.body
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if isActiveNetwork {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.deleteOutgoingMessage(id: message.id) }
                            }
                        }
                    }
                }
            case .trash:
                Section {
                    EmptyView()
                } header: {
                    MailboxSummaryHeader(
                        networkName: networkName,
                        networkConnectivity: networkConnectivity,
                        mailbox: .trash,
                        unreadCount: 0,
                        queuedCount: 0,
                        messageCount: visibleIncomingMessages.count + visibleOutgoingMessages.count,
                        lastUpdated: nil
                    )
                }

                ForEach(visibleIncomingMessages) { message in
                    incomingMessageLink(for: message)
                }
                ForEach(visibleOutgoingMessages) { message in
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
                    .swipeActions(edge: .leading) {
                        if isActiveNetwork {
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                model.restoreMessage(id: message.id)
                            }
                            .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if isActiveNetwork {
                            Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                                model.permanentlyDeleteOutgoingMessage(id: message.id)
                            }
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
            } else if selection.mailbox == .trash && visibleIncomingMessages.isEmpty && visibleOutgoingMessages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "trash")
            } else if selection.mailbox != .inbox && selection.mailbox != .trash && visibleOutgoingMessages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: selection.mailbox.systemImage)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isActiveNetwork {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use for Messaging", systemImage: "bubble.left.fill", action: makeActive)
                }
            } else if selection.mailbox == .inbox {
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
                        model.discardDraft()
                        showingComposer = true
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Compose", systemImage: "square.and.pencil") {
                        model.discardDraft()
                        showingComposer = true
                    }
                }
            }
        }
        .onAppear { updateVisibleIncomingMessages() }
        .onChange(of: storedIncomingMessages) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: storedMailboxMetadata) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: isActiveNetwork) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: model.incomingMessages) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: model.readMessageIDs) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: model.flaggedMessageIDs) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: model.trashedMessageIDs) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: inboxFilter) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: searchText) { _, _ in updateVisibleIncomingMessages() }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelNetworkRefreshPresentation()
        }
        .sheet(isPresented: $showingComposer, onDismiss: model.discardDraft) {
            IOSMessageComposerView(model: model, dismiss: { showingComposer = false })
        }
        .sheet(item: $presentedMessageInfo) { info in
            MessageInfoView(info: info)
        }
        // Own the destination outside the rows: marking an unread message
        // read can remove its row without dismissing the open message.
        .navigationDestination(isPresented: Binding(
            get: { selectedIncomingMessage != nil },
            set: { if !$0 { selectedIncomingMessage = nil } }
        )) {
            if let message = selectedIncomingMessage {
                IOSIncomingMessageDetail(
                    message: message,
                    senderName: message.source.map(displayName) ?? "Unknown Sender",
                    model: model,
                    isActiveNetwork: isActiveNetwork
                )
                .task {
                    guard isActiveNetwork else { return }
                    await model.openIncomingMessage(message)
                }
            }
        }
    }

    private func incomingMessageLink(for message: IncomingMessage) -> some View {
        Button {
            selectedIncomingMessage = message
        } label: {
            HStack(alignment: .top, spacing: 8) {
                IncomingMailRow(
                    sender: message.source.map(displayName) ?? "Unknown Sender",
                    subject: message.subject,
                    preview: message.preview,
                    receivedAt: message.receivedAt,
                    isRead: isRead(message.id),
                    isFlagged: isFlagged(message.id)
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens message")
        .swipeActions(edge: .leading) {
            if !isActiveNetwork {
                EmptyView()
            } else if selection.mailbox == .trash {
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    model.restoreMessage(id: message.id)
                }
                .tint(.blue)
            } else {
                Button(model.isRead(message.id) ? "Unread" : "Read") {
                    model.setRead(!model.isRead(message.id), messageID: message.id)
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isActiveNetwork {
                EmptyView()
            } else if selection.mailbox == .trash {
                Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                    Task { await model.permanentlyDeleteIncomingMessage(id: message.id) }
                }
            } else {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await model.deleteIncomingMessage(id: message.id) }
                }
            }

            if isActiveNetwork {
                Button(model.isFlagged(message.id) ? "Unflag" : "Flag") {
                    model.toggleFlag(messageID: message.id)
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if isActiveNetwork {
                ControlGroup {
                if let source = message.source, model.isAddressable(source) {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") {
                        model.prepareReply(to: message)
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
            }

            if isActiveNetwork {
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
            }

            Button("Message Info", systemImage: "info.circle") {
                presentedMessageInfo = .incoming(message)
            }
        } preview: {
            MessageContextPreview(
                heading: message.source.map(displayName) ?? "Unknown Sender",
                metadata: message.receivedAt.formatted(date: .abbreviated, time: .shortened),
                subject: message.subject,
                messageBody: message.body
            )
        }
    }

    private func updateVisibleIncomingMessages() {
        let trashedMessageIDs = isActiveNetwork ? model.trashedMessageIDs : storedMailboxMetadata.trashedMessageIDs
        visibleIncomingMessages = sourceIncomingMessages.filter { message in
            let isTrashed = trashedMessageIDs.contains(message.id)
            if selection.mailbox == .trash {
                return isTrashed
            }
            guard !isTrashed else { return false }
            let matchesFilter = switch inboxFilter {
            case .all: true
            case .unread: !isRead(message.id)
            case .flagged: isFlagged(message.id)
            }
            guard matchesFilter else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let sender = message.source.map(displayName) ?? "Unknown Sender"
            return sender.localizedCaseInsensitiveContains(query)
                || message.subject.localizedCaseInsensitiveContains(query)
                || message.body.localizedCaseInsensitiveContains(query)
        }
    }

    private func performNetworkRefresh() async {
        guard isActiveNetwork, refreshPhase != .refreshing else { return }
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

    private var sourceIncomingMessages: [IncomingMessage] {
        isActiveNetwork ? model.incomingMessages : storedIncomingMessages
    }

    private func displayName(for address: UUID) -> String {
        if isActiveNetwork {
            return model.displayName(for: address)
        }
        return storedMailboxMetadata.recipients.first(where: { $0.id == address })?.name
            ?? address.uuidString
    }

    private func isRead(_ messageID: UUID) -> Bool {
        isActiveNetwork
            ? model.isRead(messageID)
            : storedMailboxMetadata.readMessageIDs.contains(messageID)
    }

    private func isFlagged(_ messageID: UUID) -> Bool {
        isActiveNetwork
            ? model.isFlagged(messageID)
            : storedMailboxMetadata.flaggedMessageIDs.contains(messageID)
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
    var showSubtitleInformation: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())

            if let subtitle {
                HStack(spacing: 0) {
                    Text(subtitle)
                        .font(.headline.bold())
                        .foregroundStyle(.secondary)

                    if let showSubtitleInformation {
                        Button(action: showSubtitleInformation) {
                            Image(systemName: "info.circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("About Network Status Colors")
                    }
                }
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
    var requiresAttention = false
    var isStarting = false
    let appleNetworkSnapshot: AppleNetworkSnapshot
    let topSpacingAdjustment: CGFloat
    var credentialStatus: NetworkCredentialStatus? = nil

    private var connectionProgress: LocalizedStringResource {
        guard isActive else { return "Inactive" }
        if let credentialStatus { return credentialStatus.title }
        if case .connected(let count) = connectivity {
            return "\(count + 1) Devices Online"
        }
        if connectivity == .failed {
            return "Connection failed"
        }
        if isStarting { return "Preparing connection…" }
        if requiresAttention { return "Setup needs attention" }
        switch connectivity {
        case .discoveringPeers:
            return "Finding devices…"
        case .readyNoPeers:
            return "1 Device Online"
        case .reconnecting:
            return "Checking connection…"
        case .inactive:
            return "No Beakr network detected"
        case .localNetworkDenied:
            return "Local Network Permission Required"
        case .connected, .failed:
            return "Checking connection…"
        }
    }

    private var statusColor: Color {
        if isStarting { return .blue }
        if requiresAttention {
            return .red
        }
        return isActive ? connectivity.statusColor : .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isActive ? "network.badge.shield.half.filled" : "network.slash")
                .imageScale(.large)
                .fixedSize()
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
                .symbolEffect(
                    .pulse,
                    options: .repeating.speed(0.7),
                    isActive: isActive && (isStarting || connectivity.isTransitioning)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .foregroundStyle(statusColor)
                Text(appleNetworkSnapshot.compactConnectionDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(connectionProgress)
                    .font(.subheadline)
                    .foregroundStyle(connectivity == .localNetworkDenied ? Color.red : Color.secondary)
                    .lineLimit(connectivity == .localNetworkDenied ? nil : 1)
                if isActive && connectivity == .localNetworkDenied {
                    Text("Beakr does not have Local Network permission. Enable it for Beakr in Settings, then return to the app.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textCase(nil)
        .padding(.top, topSpacingAdjustment)
        .accessibilityElement(children: .combine)
        .traceNetworkIndicator(
            "network-mailbox-header",
            details: "color=\(statusColor) active=\(isActive) starting=\(isStarting) requiresAttention=\(requiresAttention) connectivity=\(connectivity)"
        )
    }
}

private enum NetworkRefreshPhase: Equatable {
    case idle
    case refreshing
    case settling
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

#endif

struct AppleNetworkSnapshot: Equatable {
    enum InternetRoute: Equatable {
        case wifi
        case ethernet
        case cellular
        case other
        case unavailable

        var description: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .ethernet: "Ethernet"
            case .cellular: "Cellular"
            case .other: "Other"
            case .unavailable: "Unavailable"
            }
        }
    }

    let wifiName: String?
    let internetRoute: InternetRoute
    let checkedAt: Date
    var localRoute: InternetRoute = .unavailable
    var localAddress: String?
    var localIPv4Address: String? {
        guard let localAddress, !localAddress.contains(":") else { return nil }
        return localAddress
    }
    var hasChecked = false

    static let unknown = AppleNetworkSnapshot(
        wifiName: nil,
        internetRoute: .unavailable,
        checkedAt: Date()
    )

    var compactConnectionDetail: LocalizedStringResource {
        guard hasChecked else { return "Checking network…" }
        if localRoute == .wifi, let wifiName, !wifiName.isEmpty {
            return "Wi-Fi: \(wifiName)"
        }
        if let localAddress { return "This Device IP: \(localAddress)" }
        switch localRoute {
        case .wifi: return "Wi-Fi · This Device IP: Unavailable"
        case .ethernet: return "Ethernet · This Device IP: Unavailable"
        case .cellular: return "Cellular"
        case .other: return "Other connection"
        case .unavailable: return "No local connection"
        }
    }

    var connectionDetail: LocalizedStringResource {
        guard hasChecked else { return "Checking this device’s network…" }
        switch localRoute {
        case .wifi:
            if let wifiName, let localAddress {
                return "Wi-Fi: \(wifiName) · This Device IP: \(localAddress)"
            }
            if let localAddress {
                return "Wi-Fi: Name unavailable · This Device IP: \(localAddress)"
            }
            return "Wi-Fi · This Device IP: Unavailable"
        case .ethernet:
            if let localAddress { return "Ethernet · This Device IP: \(localAddress)" }
            return "Ethernet · This Device IP: Unavailable"
        case .cellular:
            return "Cellular · No Wi-Fi or Ethernet address found"
        case .other:
            return "Other connection · Local network not identified"
        case .unavailable:
            return "No Wi-Fi or Ethernet address found"
        }
    }

    var appleNetworkDescription: String {
        String(localized: connectionDetail)
    }

    static func capture() async -> AppleNetworkSnapshot {
        for await path in CurrentInternetRouteProbe.updates() {
            return await capture(path: path)
        }
        return .unknown
    }

    static func capture(path: Network.NWPath, includesWiFiName: Bool = true) async -> AppleNetworkSnapshot {
        let route: InternetRoute
        if path.status != .satisfied {
            route = .unavailable
        } else if path.usesInterfaceType(.wiredEthernet) {
            route = .ethernet
        } else if path.usesInterfaceType(.wifi) {
            route = .wifi
        } else if path.usesInterfaceType(.cellular) {
            route = .cellular
        } else {
            route = .other
        }

        // A cellular default route can coexist with a usable local Wi-Fi link.
        // Identify a physical LAN interface with an assigned address, rather
        // than presenting a VPN or cellular address as the Beakr LAN address.
        let interfaces = path.availableInterfaces.sorted {
            let lhsUsed = path.usesInterfaceType($0.type)
            let rhsUsed = path.usesInterfaceType($1.type)
            if lhsUsed != rhsUsed { return lhsUsed }
            return $0.name < $1.name
        }
        let localInterface = interfaces.first { interface in
            (interface.type == .wifi || interface.type == .wiredEthernet)
                && address(for: interface.name) != nil
        }
        let localRoute: InternetRoute
        if let localInterface {
            localRoute = localInterface.type == .wifi ? .wifi : .ethernet
        } else {
            localRoute = route
        }
        let wifiName = includesWiFiName && localRoute == .wifi ? await currentWiFiName() : nil
        return AppleNetworkSnapshot(
            wifiName: wifiName,
            internetRoute: route,
            checkedAt: Date(),
            localRoute: localRoute,
            localAddress: localInterface.flatMap { address(for: $0.name) },
            hasChecked: true
        )
    }

    private static func address(for interfaceName: String) -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var ipv6Address: String?
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard String(cString: interface.ifa_name) == interfaceName,
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  let address = interface.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET, value != "0.0.0.0" { return value }
            if family == AF_INET6, value != "::" { ipv6Address = ipv6Address ?? value }
        }
        return ipv6Address
    }

    private static func currentWiFiName() async -> String? {
        #if os(iOS)
        await WiFiNameAccess.shared.currentName()
        #else
        nil
        #endif
    }
}

nonisolated enum CurrentInternetRouteProbe {
    static func updates() -> AsyncStream<Network.NWPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "net.beakr.network-details"))
        }
    }
}

#if os(iOS)
private extension ActiveNetworkConnectivity {
    var peekDescription: String {
        switch self {
        case .inactive: "Inactive"
        case .reconnecting: "Checking Local Network"
        case .discoveringPeers: "Discovering devices"
        case .readyNoPeers: "1 Device Online"
        case .connected(let peerCount): "\(peerCount + 1) Devices Online"
        case .localNetworkDenied: "Local Network Permission Required"
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
                            if model.messageText.isEmpty { dismiss() }
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

private struct InvitationReviewPresentation: Identifiable {
    let id = UUID()
    let review: InvitationReview
    let repairProfileID: NetworkProfileID?
}

private struct IOSBeakrManagementView: View {
    let model: MessageComposerModel
    @Bindable var bootstrap: NodeBootstrapModel
    let initialNetworkID: NetworkProfileID?
    let joinCompleted: () -> Void
    let dismiss: () -> Void
    var scannerReturnRoute: InvitationScannerReturnRoute? = nil
    @State private var restoredScannerRoute = false
    @State private var returnToRootAfterReview = false
    @State private var showingInvitationScanner = false
    @State private var pendingScannedInvitation: String?
    @State private var invitationPresentation: InvitationReviewPresentation?
    @State private var repairTargetNetworkID: NetworkID?
    @State private var repairTargetProfileID: NetworkProfileID?

    var body: some View {
        NavigationStack {
            if let initialNetworkID {
                IOSNetworkDetailView(
                    bootstrap: bootstrap,
                    networkID: initialNetworkID,
                    scanRepairInvitation: scanRepairInvitation,
                    pasteRepairInvitation: pasteRepairInvitation
                )
            } else {
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
                        Label("Networks", systemImage: "network.badge.shield.half.filled")
                            .badge(bootstrap.networkSessions.filter(\.isDisplayable).count)
                    }

                    NavigationLink {
                        IOSDeviceSettingsView(bootstrap: bootstrap)
                    } label: {
                        Label("This Device", systemImage: "iphone")
                    }
                    NavigationLink {
                        MessagingServicesView(bootstrap: bootstrap)
                    } label: {
                        Label("Services", systemImage: "square.stack.3d.up")
                    }
                }

                WiFiNamePermissionSection()

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
                .navigationTitle("Settings")
            }
        }
        .task {
            guard !restoredScannerRoute, let route = scannerReturnRoute else { return }
            restoredScannerRoute = true
            repairTargetProfileID = route.repairProfileID.map { NetworkProfileID(rawValue: $0) }
            repairTargetNetworkID = route.repairNetworkID.map { NetworkID(rawValue: $0) }
            showingInvitationScanner = true
        }
        .sheet(isPresented: $showingInvitationScanner, onDismiss: {
            InvitationScannerReturnRoute.clear()
            presentScannedInvitationReview()
        }) {
            InvitationScannerSheet(
                initialNetworkID: initialNetworkID?.rawValue,
                repairProfileID: repairTargetProfileID?.rawValue,
                repairNetworkID: repairTargetNetworkID?.rawValue
            ) { invitation in
                InvitationScannerReturnRoute.clear()
                pendingScannedInvitation = invitation
                showingInvitationScanner = false
            }
        }
        .sheet(item: $invitationPresentation, onDismiss: {
            // Finish dismissing the review before dismissing its Settings presenter.
            guard returnToRootAfterReview else { return }
            returnToRootAfterReview = false
            joinCompleted()
        }) { presentation in
            InvitationReviewSheet(
                bootstrap: bootstrap,
                review: presentation.review,
                repairProfileID: presentation.repairProfileID,
                joinCompleted: {
                    returnToRootAfterReview = true
                    invitationPresentation = nil
                    repairTargetNetworkID = nil
                    repairTargetProfileID = nil
                },
                dismiss: {
                    bootstrap.traceInvitationUI(
                        "presentation-dismiss-request invitation=\(presentation.review.id) repairProfile=\(presentation.repairProfileID?.rawValue.uuidString ?? "none")"
                    )
                    invitationPresentation = nil
                    repairTargetNetworkID = nil
                    repairTargetProfileID = nil
                }
            )
            .id(presentation.id)
            .presentationDragIndicator(.visible)
        }
    }

    private func scanInvitation() {
        repairTargetNetworkID = nil
        repairTargetProfileID = nil
        showingInvitationScanner = true
    }

    private func scanRepairInvitation(_ profileID: NetworkProfileID) {
        guard let network = bootstrap.networks.first(where: { $0.id == profileID }) else { return }
        repairTargetNetworkID = network.networkID
        repairTargetProfileID = profileID
        bootstrap.prepareForNetworkJoin()
        showingInvitationScanner = true
    }

    private func pasteRepairInvitation(_ profileID: NetworkProfileID) {
        guard let network = bootstrap.networks.first(where: { $0.id == profileID }) else { return }
        repairTargetNetworkID = network.networkID
        repairTargetProfileID = profileID
        bootstrap.prepareForNetworkJoin()
        guard let invitation = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !invitation.isEmpty else {
            repairTargetNetworkID = nil
            repairTargetProfileID = nil
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
            repairTargetProfileID = nil
            return
        }
        if let repairTargetNetworkID,
           review.networkID != repairTargetNetworkID {
            self.repairTargetNetworkID = nil
            repairTargetProfileID = nil
            bootstrap.networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Invitation Is for Another Network",
                message: "Repair requires a current invitation for the selected Beakr'Net. No network profile was changed."
            )
            return
        }
        if repairTargetNetworkID == nil,
           let existingNetwork = bootstrap.networks.first(where: { $0.networkID == review.networkID }) {
            if existingNetwork.canExchangeMessages {
                bootstrap.joinInvitationJSON = ""
                bootstrap.networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: existingNetwork.displayName,
                    message: "This iPhone already has a membership credential for the \(existingNetwork.displayName) network. No network changes will be made."
                )
                return
            }
            // An incomplete enrollment also has a saved profile. Route its fresh
            // invitation through repair instead of treating it as admitted membership.
            repairTargetNetworkID = existingNetwork.networkID
            repairTargetProfileID = existingNetwork.id
        }
        bootstrap.networkJoinAlert = nil
        let presentation = InvitationReviewPresentation(
            review: review,
            repairProfileID: repairTargetProfileID
        )
        bootstrap.traceInvitationUI(
            "presentation-set invitation=\(review.id) presentation=\(presentation.id) repairProfile=\(presentation.repairProfileID?.rawValue.uuidString ?? "none")"
        )
        invitationPresentation = presentation
    }
}

private struct IOSNetworkManagerView: View {
    @Bindable var bootstrap: NodeBootstrapModel
    let scanInvitation: () -> Void
    let reviewInvitation: (String) -> Void
    let scanRepairInvitation: (NetworkProfileID) -> Void
    let pasteRepairInvitation: (NetworkProfileID) -> Void

    private var networkSessions: [NetworkSession] {
        bootstrap.networkSessions.filter(\.isDisplayable)
    }

    var body: some View {
        List {
            Section {
                if networkSessions.isEmpty {
                    ContentUnavailableView(
                        "No Networks",
                        systemImage: "network.slash",
                        description: Text("An invitation is required to join a network.")
                    )
                } else {
                    ForEach(networkSessions) { session in
                    NavigationLink {
                        IOSNetworkDetailView(
                            bootstrap: bootstrap,
                            networkID: session.id,
                            scanRepairInvitation: scanRepairInvitation,
                            pasteRepairInvitation: pasteRepairInvitation
                        )
                    } label: {
                        HStack {
                            Image(systemName: session.isSelected
                                  ? "network.badge.shield.half.filled"
                                  : "network.slash")
                                .foregroundStyle(
                                    session.isSelected
                                        ? session.connectivity.statusColor
                                        : Color.secondary
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.summary.displayName)
                                Text(
                                    bootstrap.hasPendingJoiningRequest && session.isSelected
                                        ? (bootstrap.state == .failed ? "Join Needs Attention" : "Joining…")
                                        : session.statusTitle
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    bootstrap.hasPendingJoiningRequest && session.isSelected
                                        ? Color.orange
                                        : (session.isSelected
                                            ? session.connectivity.statusColor
                                            : Color.secondary)
                                )
                            }
                            Spacer()
                            if session.isSelected {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(session.connectivity.statusColor)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    }
                }
            } footer: {
                Text("--")
            }

            Section {
                Button("Scan Invitation QR Code", systemImage: "qrcode.viewfinder") {
                    bootstrap.prepareForNetworkJoin()
                    scanInvitation()
                }
                .disabled(bootstrap.state == .joiningNetwork)

                HStack {
                    Text("Paste JSON")
                    Spacer()
                    PasteButton(payloadType: String.self) { strings in
                        reviewPastedInvitation(strings)
                    }
                    .accessibilityLabel("Paste invitation JSON")
                }
                .disabled(bootstrap.state == .joiningNetwork)
            } header: {
                Text("Add Network")
            } footer: {
                Text("--")
            }

            if !networkSessions.isEmpty,
               bootstrap.state == .joiningNetwork || bootstrap.state == .failed {
                DeviceOperationStatusSection(
                    state: bootstrap.state,
                    statusMessage: bootstrap.statusMessage
                )
            }

            if bootstrap.hasPendingJoiningRequest {
                Section {
                    Button("Cancel Pending Request", systemImage: "xmark.circle", role: .destructive) {
                        Task { await bootstrap.cancelPendingNetworkJoin() }
                    }
                } header: {
                    Text(bootstrap.state == .failed ? "Join Needs Attention" : "Joining…")
                } footer: {
                    Text(bootstrap.statusMessage)
                }
            }
        }
        .navigationTitle("Networks")
        .refreshable { await bootstrap.refreshNetworkCredentials() }
        .networkJoinAlert(
            $bootstrap.standaloneNetworkJoinAlert,
            confirmCollision: { Task { await bootstrap.confirmCollidingNetworkJoin() } },
            confirmReattachment: { Task { await bootstrap.confirmContextReattachment() } }
        )
    }

    private func reviewPastedInvitation(_ strings: [String]) {
        guard bootstrap.state != .joiningNetwork else { return }
        bootstrap.prepareForNetworkJoin()
        guard let pastedInvitation = strings.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !pastedInvitation.isEmpty else {
            bootstrap.networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "No Invitation Found",
                message: "Copy a Beakr invitation JSON document, then tap Paste."
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
    let repairProfileID: NetworkProfileID?
    let joinCompleted: () -> Void
    let dismiss: () -> Void
    @State private var isJoining = false
    @State private var result: NetworkJoinAlert?
    @State private var traceInstanceID = UUID()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isAwaitingApproval = bootstrap.hasPendingJoiningRequest && bootstrap.state != .failed
            let isExpired = review.isExpired(at: context.date) && !isAwaitingApproval

            NavigationStack {
                ScrollView {
                    VStack(spacing: 24) {
                        InvitationReviewHeader(
                            networkName: review.networkDisplayName,
                            authorityHost: review.authorityURL.host ?? review.authorityURL.absoluteString,
                            isExpired: isExpired,
                            isAwaitingApproval: isAwaitingApproval
                        )
                        if isExpired {
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
                .navigationTitle("Join Network")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    InvitationReviewActions(
                        isExpired: isExpired,
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
        .onChange(of: bootstrap.networkJoinAlert) { _, _ in
            // Synchronous join actions consume their own result. Polling continues
            // after those actions return, so keep the visible review up to date.
            guard !isJoining, result?.invitationAccepted == true,
                  let updated = bootstrap.consumeInvitationReviewResult() else { return }
            result = updated
        }
        .onChange(of: result) { _, updated in
            guard updated?.succeeded == true else { return }
            isJoining = false
            bootstrap.networkJoinAlert = nil
            joinCompleted()
        }
        .onAppear {
            bootstrap.isInvitationReviewPresented = true
            bootstrap.traceInvitationUI(
                "sheet-appear instance=\(traceInstanceID) invitation=\(review.id) repairProfile=\(repairProfileDescription)"
            )
        }
        .onDisappear {
            bootstrap.isInvitationReviewPresented = false
            bootstrap.traceInvitationUI(
                "sheet-disappear instance=\(traceInstanceID) invitation=\(review.id) joining=\(isJoining) hasResult=\(result != nil)"
            )
        }
    }

    private var repairProfileDescription: String {
        repairProfileID?.rawValue.uuidString ?? "none"
    }

    private func reject() {
        bootstrap.rejectInvitation(review)
        dismiss()
    }

    private func accept() {
        guard !isJoining else {
            bootstrap.traceInvitationUI(
                "join-tap-ignored instance=\(traceInstanceID) invitation=\(review.id) reason=already-joining"
            )
            return
        }
        bootstrap.traceInvitationUI(
            "join-tap instance=\(traceInstanceID) invitation=\(review.id) repairProfile=\(repairProfileDescription)"
        )
        isJoining = true
        result = nil
        bootstrap.networkJoinAlert = nil
        Task {
            if let repairProfileID {
                result = await bootstrap.repairExistingNetwork(
                    using: review,
                    profileID: repairProfileID
                )
            } else {
                await bootstrap.acceptInvitation(review)
                result = bootstrap.networkJoinAlert
                bootstrap.networkJoinAlert = nil
            }
            bootstrap.traceInvitationUI(
                "join-result instance=\(traceInstanceID) invitation=\(review.id) present=\(result != nil) accepted=\(result?.invitationAccepted == true) succeeded=\(result?.succeeded == true)"
            )
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
            result = await bootstrap.repairExistingNetwork(
                using: review,
                profileID: profileID
            )
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
    let isAwaitingApproval: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: headerSystemImage)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.hierarchical)
            Text("Join \(networkName)?")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(statusDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label(statusTitle, systemImage: statusSystemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var statusTitle: LocalizedStringResource {
        if isAwaitingApproval { return "Awaiting Approval" }
        return isExpired ? "Expired" : "Ready to Join"
    }

    private var statusDescription: LocalizedStringResource {
        if isAwaitingApproval {
            return "A network administrator must approve this iPhone before it can finish joining."
        }
        if isExpired { return "This invitation has expired." }
        return "\(authorityHost) is inviting this iPhone to join this Beakr'Net."
    }

    private var headerSystemImage: String {
        if isAwaitingApproval { return "hourglass.circle.fill" }
        return isExpired ? "clock.badge.exclamationmark.fill" : "network.badge.shield.half.filled"
    }

    private var statusSystemImage: String {
        if isAwaitingApproval { return "hourglass" }
        return isExpired ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if isAwaitingApproval { return .orange }
        return isExpired ? .red : .green
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
                Button("Close", action: done)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if result?.invitationAccepted == true {
                Button("Close", action: done)
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
                Button("Close", action: reject)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if result != nil {
                Button("Close", action: done)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Join Network", action: accept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isJoining)
                Button("Cancel", action: reject)
                    .disabled(isJoining)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }
}

private struct IOSRemoveNetworksView: View {
    @Environment(\.dismiss) private var dismiss

    let networks: [NetworkSummary]
    let connectivity: ActiveNetworkConnectivity
    let removeAndKeepData: (NetworkProfileID) async -> Void
    let removeAndDeleteData: (NetworkProfileID) async -> Void
    @State private var selectedNetwork: NetworkSummary?

    var body: some View {
        NavigationStack {
            List {
                if networks.isEmpty {
                    ContentUnavailableView(
                        "No Removable Networks",
                        systemImage: "network.slash",
                        description: Text("Authority-hosted networks must be deleted from their Network settings.")
                    )
                } else {
                    Section {
                        ForEach(networks) { network in
                            Button(role: .destructive) {
                                selectedNetwork = network
                            } label: {
                                Label(network.displayName, systemImage: "minus.circle.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } footer: {
                        Text("Select a network to remove it from this iPhone. The network authority is not deleted.")
                    }
                }
            }
            .navigationTitle("Remove Networks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $selectedNetwork) { network in
            IOSForgetNetworkSheet(
                network: network,
                connectivity: connectivity,
                forgetAndKeepData: {
                    Task {
                        await removeAndKeepData(network.id)
                        selectedNetwork = nil
                    }
                },
                forgetAndDeleteData: {
                    Task {
                        await removeAndDeleteData(network.id)
                        selectedNetwork = nil
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct IOSForgetNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss

    let network: NetworkSummary
    let connectivity: ActiveNetworkConnectivity
    let forgetAndKeepData: () -> Void
    let forgetAndDeleteData: () -> Void
    @State private var pendingDisposition: ForgottenNetworkDataDisposition?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remove \(network.displayName)?")
                            .font(.title2.bold())
                        Text("This removes the network from this iPhone only.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button(
                            "Remove and Keep Data",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            pendingDisposition = .keepLocalData
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)

                        Text("Removes this network's identity and credentials, while keeping its messages on this iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Remove and Delete Data", systemImage: "trash", role: .destructive) {
                            pendingDisposition = .deleteLocalData
                        }
                        .controlSize(.large)

                        Text("Also permanently deletes this network's local messages and other stored data from this iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if network.isActive, connectivity == .inactive {
                        Label {
                            Text("This network may simply be out of range. Removing it will not restore connectivity.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        consequence(
                            title: "Removed from This iPhone",
                            description: "The local identity, credentials, and connection for this network are removed."
                        )
                        consequence(
                            title: "A New Invitation Is Required",
                            description: "To join again, you will need a new invitation from the network authority. The network and its authority are not deleted."
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Remove Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Remove \(network.displayName) from This iPhone?",
            isPresented: Binding(
                get: { pendingDisposition != nil },
                set: { if !$0 { pendingDisposition = nil } }
            )
        ) {
            if pendingDisposition == .keepLocalData {
                Button("Remove and Keep Data", role: .destructive) {
                    pendingDisposition = nil
                    forgetAndKeepData()
                }
            } else if pendingDisposition == .deleteLocalData {
                Button("Remove and Delete Data", role: .destructive) {
                    pendingDisposition = nil
                    forgetAndDeleteData()
                }
            }
            Button("Keep Network", role: .cancel) {
                pendingDisposition = nil
            }
        } message: {
            Text("A new invitation will be required to join this network again.")
        }
    }

    private func consequence(title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(description)
                .foregroundStyle(.secondary)
        }
    }
}

private struct IOSNetworkDetailView: View {
    @Bindable var bootstrap: NodeBootstrapModel
    let networkID: NetworkProfileID
    let scanRepairInvitation: (NetworkProfileID) -> Void
    let pasteRepairInvitation: (NetworkProfileID) -> Void
    @State private var confirmingDeparture = false
    @State private var confirmingDeletion = false
    @State private var isRenamingNetwork = false
    @State private var editedNetworkName = ""
    @State private var isSavingNetworkName = false
    @State private var presentedSectionInformation: NetworkSectionInformation?

    private var network: NetworkSummary? {
        bootstrap.networks.first { $0.id == networkID }
    }

    var body: some View {
        ZStack {
            Form {
                if let network {
                Section {
                    LabeledContent("Name") {
                        HStack {
                            Text(network.displayName)
                                .multilineTextAlignment(.trailing)
                            if network.isHostingAuthority {
                                Button("Rename Network", systemImage: "pencil") {
                                    editedNetworkName = network.displayName
                                    isRenamingNetwork = true
                                }
                                .labelStyle(.iconOnly)
                                .disabled(isSavingNetworkName)
                            }
                        }
                    }
                    NetworkInformationRow("Network ID") {
                        Text(network.networkID.rawValue.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    NetworkLastErrorDisclosure(
                        message: bootstrap.networkSessions.first(where: { $0.id == network.id })?.lastError
                    )
                    NetworkCredentialDetailsView(bootstrap: bootstrap, network: network)
                }

                Section {
                    NetworkAddressesContent(
                        localName: bootstrap.deviceDisplayName,
                        localID: bootstrap.localNodeID(for: network.id),
                        isNetworkActive: network.isActive,
                        localDeviceIsMember: !network.isActive || bootstrap.state == .ready,
                        members: bootstrap.members(for: network),
                        onlineMemberIDs: network.isActive ? bootstrap.onlineMemberIDs : [],
                        isLocalDeviceOnline: network.isActive
                            && bootstrap.activeNetworkConnectivity.isLocalDeviceOnline,
                        authorityDeviceName: network.isActive ? bootstrap.activeAuthorityDeviceName : nil,
                        isLocalDeviceAuthority: network.isHostingAuthority,
                        localCanManageNetwork: network.canManageNetwork,
                        membershipNotice: (bootstrap.savedMemberships[network.id] ?? .unavailable).notice
                    )
                    if network.isHostingAuthority {
                        DisclosureGroup("Device Registration") {
                            NavigationLink {
                                IOSNetworkInvitationsView(
                                    bootstrap: bootstrap,
                                    networkID: network.id
                                )
                            } label: {
                                Label("Invitation", systemImage: "qrcode")
                            }
                            .accessibilityIdentifier("networkInvitationsButton")
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Devices in This Network")
                        NetworkSectionInformationButton(
                            information: .devices,
                            show: { presentedSectionInformation = $0 }
                        )
                    }
                }

                Section {
                    if network.isActive {
                        if bootstrap.state != .ready {
                            Menu {
                                Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                                    scanRepairInvitation(network.id)
                                }
                                Button("Paste", systemImage: "doc.on.clipboard") {
                                    pasteRepairInvitation(network.id)
                                }
                            } label: {
                                Label("Invitation…", systemImage: "qrcode")
                            }
                            .accessibilityIdentifier("rejoinInvitationButton")
                        }
                    } else {
                        Button("Use for Messaging", systemImage: "bubble.left.fill") {
                            activateNetwork(network.id)
                        }
                        .disabled(bootstrap.state == .securing || bootstrap.state == .starting)
                    }

                    if network.isHostingAuthority {
                        Button("Delete Network…", systemImage: "trash", role: .destructive) {
                            confirmingDeletion = true
                        }
                    } else {
                        Button(
                            "Forget Network…",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            confirmingDeparture = true
                        }
                    }
                }

                } else {
                    ContentUnavailableView("Network Unavailable", systemImage: "network.slash")
                }
            }
            .disabled(isRenamingNetwork)
            .accessibilityHidden(isRenamingNetwork)

            if isRenamingNetwork, let network {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                IOSRenameNetworkDialog(
                    name: $editedNetworkName,
                    canSave: canSaveName(for: network),
                    isSaving: isSavingNetworkName,
                    cancel: { isRenamingNetwork = false },
                    save: {
                        isRenamingNetwork = false
                        saveNetworkName(network)
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isRenamingNetwork)
        .sheet(item: $presentedSectionInformation) { information in
            NetworkSectionInformationView(information: information)
        }
        .navigationTitle(network?.displayName ?? "Network")
        .onAppear {
            editedNetworkName = network?.displayName ?? ""
        }
        .onChange(of: network?.displayName) { _, newName in
            guard !isSavingNetworkName, !isRenamingNetwork else { return }
            editedNetworkName = newName ?? ""
        }
        .sheet(isPresented: $confirmingDeparture) {
            if let network {
                IOSForgetNetworkSheet(
                    network: network,
                    connectivity: bootstrap.activeNetworkConnectivity,
                    forgetAndKeepData: {
                        confirmingDeparture = false
                        Task {
                            await bootstrap.forgetJoinedNetwork(
                                network.id,
                                dataDisposition: .keepLocalData
                            )
                        }
                    },
                    forgetAndDeleteData: {
                        confirmingDeparture = false
                        Task {
                            await bootstrap.forgetJoinedNetwork(
                                network.id,
                                dataDisposition: .deleteLocalData
                            )
                        }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog("Delete Network?", isPresented: $confirmingDeletion) {
            if let network {
                Button("Delete \(network.displayName)", role: .destructive) {
                    Task { await bootstrap.deleteOwnedNetwork(network.id) }
                }
            }
            Button("Keep Network", role: .cancel) {}
        } message: {
            if let network {
                Text("This permanently removes \(network.displayName), its management credentials, and its local data.")
            }
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
            await bootstrap.renameOwnedNetwork(network.id, to: editedNetworkName)
            editedNetworkName = bootstrap.networks.first(where: { $0.id == network.id })?.displayName
                ?? network.displayName
            isSavingNetworkName = false
        }
    }

    private func activateNetwork(_ networkID: NetworkProfileID) {
        Task {
            await bootstrap.switchNetwork(to: networkID)
            guard !Task.isCancelled else { return }
        }
    }
}

private struct IOSNetworkInvitationsView: View {
    @Bindable var bootstrap: NodeBootstrapModel
    let networkID: NetworkProfileID

    private var network: NetworkSummary? {
        bootstrap.networks.first { $0.id == networkID }
    }

    var body: some View {
        Form {
            if let network, network.isHostingAuthority {
                InviteDeviceSection(
                    invitation: network.isActive ? bootstrap.invitationJSON : "",
                    isConsumed: bootstrap.invitationIsConsumed(bootstrap.invitationJSON),
                    create: { Task { await bootstrap.createInvitation(for: network.id) } }
                )
                .disabled(!network.isActive || !bootstrap.canCreateInvitations)
            } else {
                ContentUnavailableView(
                    "Invitations Unavailable",
                    systemImage: "qrcode",
                    description: Text("This device is not hosting the network authority.")
                )
            }
        }
        .navigationTitle("Invitations")
    }
}

private struct IOSRenameNetworkDialog: View {
    @Binding var name: String
    let canSave: Bool
    let isSaving: Bool
    let cancel: () -> Void
    let save: () -> Void
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Network")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("Network Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    guard canSave, !isSaving else { return }
                    save()
                }

            HStack(spacing: 10) {
                Button("Cancel", action: cancel)
                    .frame(maxWidth: .infinity)

                Button("Save", action: save)
                    .frame(maxWidth: .infinity)
                    .disabled(!canSave || isSaving)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.separator)
        }
        .shadow(radius: 24, y: 8)
        .padding(.horizontal, 24)
        .accessibilityAddTraits(.isModal)
        .onAppear { isNameFieldFocused = true }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

private struct MessagingConnectivityDisclosure: View {
    let isActive: Bool
    let requiresAttention: Bool
    let connectivity: ActiveNetworkConnectivity
    let knownDeviceCount: Int
    let onlineDeviceCount: Int
    var credentialStatus: NetworkCredentialStatus? = nil
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 3) {
                statusRow("This Device", value: connectivity.localDeviceStatus)
                statusRow("Other Devices Online", value: onlineDeviceCount.formatted())
                statusRow(
                    "Known Devices Offline",
                    value: max(knownDeviceCount - onlineDeviceCount, 0).formatted()
                )
            }
            .padding(.top, 3)
        } label: {
            LabeledContent("Messaging Connectivity") {
                if let credentialStatus {
                    Text(credentialStatus.title)
                        .foregroundStyle(credentialStatus == .preparing ? Color.secondary : Color.red)
                } else if connectivity == .localNetworkDenied {
                    Text("Local Network Permission Required")
                        .foregroundStyle(.red)
                } else if requiresAttention {
                    Text("Setup Needs Attention")
                        .foregroundStyle(.red)
                } else if isActive {
                    Text("Active")
                        .foregroundStyle(.blue)
                } else {
                    Text("Not Active")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }
}

private struct NetworkAccessRow: View {
    let canManageNetwork: Bool

    var body: some View {
        NetworkInformationRow("Role") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(canManageNetwork ? "Manager" : "Member")
                Text(canManageNetwork
                     ? "Can manage membership and invitations"
                     : "Can join this network")
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
    let isActive: Bool

    var body: some View {
        NetworkInformationRow("Authority") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(deviceName ?? "Remote Device")
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                if isHostedHere {
                    Text("This Device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    var member: IOSMemberDetailRoute? = nil
    @State private var nameDraft = ""
    @State private var isEditingName = false

    private var displayedNetwork: NetworkSummary? {
        if let member {
            return bootstrap.networks.first { $0.id == member.profileID }
        }
        return bootstrap.networks.first(where: \.isActive)
    }

    private var displayedNodeID: UUID? {
        if let member { return member.deviceID }
        return bootstrap.nodeID
    }

    private var deviceRole: LocalizedStringResource {
        guard let displayedNetwork else { return "Not Assigned" }
        return displayedNetwork.isHostingAuthority ? "Authority" : "Member"
    }

    private var deviceStatus: LocalizedStringResource {
        guard let displayedNetwork else { return "Ready" }
        guard displayedNetwork.isActive else { return "Offline" }
        return switch bootstrap.state {
        case .starting, .creatingNetwork, .joiningNetwork, .identityReady, .securing:
            "Connecting"
        case .needsConfiguration:
            "Offline"
        case .ready:
            "Ready"
        case .failed:
            "Error"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    Button {
                        nameDraft = bootstrap.deviceDisplayName
                        isEditingName = true
                    } label: {
                        HStack(spacing: 10) {
                            Text(bootstrap.deviceDisplayName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "pencil")
                                .foregroundStyle(.blue)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit Friendly Name")
                }

                LabeledContent("Node ID") {
                    if displayedNetwork != nil, let nodeID = displayedNodeID {
                        Text(nodeID.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Text("Not Assigned")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Role") {
                    Text(deviceRole)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Status") {
                    Text(deviceStatus)
                        .foregroundStyle(bootstrap.state == .failed && displayedNetwork != nil ? .red : .secondary)
                }
            } header: {
                Text("This Device")
            } footer: {
                Text("The friendly name is stored on this iPhone. Node IDs and roles are network-specific.")
            }

            Section("Periodic Status") {
                Toggle("Allow This Device to Monitor My Status", isOn: .constant(false))
                    .disabled(true)
                Button("Start Monitoring This Device") {}
                    .disabled(true)
                Text("Monitoring applies to other devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saved Network Memberships") {
                ForEach(bootstrap.networkSessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(session.summary.displayName) {
                            Text(session.isSelected ? "Used for messaging" : "Not selected for messaging")
                                .foregroundStyle(.secondary)
                        }
                        Text(session.profile.localNodeID.rawValue.uuidString)
                            .font(.caption.monospaced()).textSelection(.enabled)
                        if !session.isSelected {
                            Text((bootstrap.savedMemberships[session.id] ?? .unavailable).notice)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !bootstrap.archivedContexts.isEmpty {
                Section("Preserved Contexts") {
                    ForEach(bootstrap.archivedContexts) { context in
                        Text(context.displayName)
                    }
                    Text("Preserved history does not establish current membership.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if displayedNetwork?.isActive == true,
               (bootstrap.state == .identityReady || bootstrap.state == .securing) {
                TrustRecoverySection(
                    isWorking: bootstrap.state == .securing,
                    enroll: { Task { await bootstrap.refreshNetworkCredentials() } }
                )
            }

        }
        .navigationTitle("This Device")
        .alert("Edit Name", isPresented: $isEditingName) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveFriendlyName()
            }
            .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This name identifies the device in Beakr networks.")
        }
        .onAppear {
            if bootstrap.deviceFriendlyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bootstrap.deviceFriendlyName = bootstrap.deviceDisplayName
            }
        }
    }

    private func saveFriendlyName() {
        bootstrap.deviceFriendlyName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await bootstrap.applyDeviceFriendlyName() }
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
                    systemImage: "tray.and.arrow.down",
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
    let displayedName: String
    @State private var nameDraft = ""
    let nodeID: UUID?
    let state: NodeBootstrapState
    let statusMessage: String
    let applyFriendlyName: (String) -> Void

    var body: some View {
        Section {
            TextField("Friendly Name", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Device Friendly Name")
                .onSubmit { applyFriendlyName(nameDraft) }

            Button("Apply Friendly Name", systemImage: "checkmark") {
                applyFriendlyName(nameDraft)
            }
            .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            LabeledContent("Node ID") {
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
            Text("The friendly name is stored on this Mac. Node IDs are network-specific.")
        }
        .onAppear { nameDraft = displayedName }
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
        case .securing:
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
    let isConsumed: Bool
    let create: () -> Void

    var body: some View {
        Section {
            if invitation.isEmpty {
                Button("Generate QR Code", systemImage: "qrcode", action: create)
            } else {
                Button("Re-Generate QR Code", systemImage: "arrow.clockwise", action: create)
            }

            if isConsumed {
                UsedInvitationNotice()
            } else if !invitation.isEmpty {
                InvitationQRCodeView(invitation: invitation)
                    .frame(width: 320)
                    .frame(minHeight: 390)

                Text(invitation)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Device Invitation JSON")

                InvitationShareLink(invitation: invitation) {
                    Label("Share JSON Invitation", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Network Invitation")
        }
    }
}

private struct NetworkAddressesContent: View {
    let localName: String
    let localID: UUID?
    let isNetworkActive: Bool
    let localDeviceIsMember: Bool
    let members: [NetworkMemberSummary]
    let onlineMemberIDs: Set<UUID>
    let isLocalDeviceOnline: Bool
    let authorityDeviceName: String?
    let isLocalDeviceAuthority: Bool
    let localCanManageNetwork: Bool
    var membershipNotice: LocalizedStringResource = "Saved membership · UnObserved"
    var isStarting = false

    private var authorityMemberID: UUID? {
        guard !isLocalDeviceAuthority, let authorityDeviceName else { return nil }
        return members.first {
            $0.displayName.localizedCaseInsensitiveCompare(authorityDeviceName) == .orderedSame
        }?.id
    }

    private var otherMembers: [NetworkMemberSummary] {
        orderedNetworkMembers(
            members.filter { $0.id != authorityMemberID },
            onlineMemberIDs: onlineMemberIDs
        )
    }

    private var rowSpacing: CGFloat {
#if os(iOS)
        8
#else
        14
#endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            if !isNetworkActive {
                Text(membershipNotice).font(.caption).foregroundStyle(.secondary)
            }
            if let authorityMember = members.first(where: { $0.id == authorityMemberID }) {
                NetworkAddressRow(
                    displayName: authorityMember.displayName,
                    deviceID: authorityMember.id,
                    detail: "Member · Network Authority",
                    isOnline: onlineMemberIDs.contains(authorityMember.id),
                    isNetworkActive: isNetworkActive
                )
            }

            NetworkAddressRow(
                displayName: localName,
                deviceID: localID,
                detail: localDeviceDetail,
                isOnline: isLocalDeviceOnline,
                isNetworkActive: isNetworkActive,
                requiresAttention: !localDeviceIsMember && !isStarting
            )

            ForEach(otherMembers) { member in
                NetworkAddressRow(
                    displayName: member.displayName,
                    deviceID: member.id,
                    detail: "Member",
                    isOnline: onlineMemberIDs.contains(member.id),
                    isNetworkActive: isNetworkActive
                )
            }
        }
    }

    private var localDeviceDetail: LocalizedStringResource {
        if isStarting { return "Connecting… · This Device" }
        if !localDeviceIsMember { return "Setup Needs Attention · This Device" }
        if isLocalDeviceAuthority { return "Member · Network Authority · This Device" }
        if localCanManageNetwork { return "Member · Manager · This Device" }
        return "Member · This Device"
    }
}

private func orderedNetworkMembers(
    _ members: [NetworkMemberSummary],
    onlineMemberIDs: Set<UUID>
) -> [NetworkMemberSummary] {
    members.sorted { lhs, rhs in
        let lhsIsOnline = onlineMemberIDs.contains(lhs.id)
        let rhsIsOnline = onlineMemberIDs.contains(rhs.id)
        if lhsIsOnline != rhsIsOnline {
            return lhsIsOnline
        }

        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct NetworkAddressRow: View {
    let displayName: String
    let deviceID: UUID?
    let detail: LocalizedStringResource?
    let isOnline: Bool
    let isNetworkActive: Bool
    var requiresAttention = false

    private var detailSpacing: CGFloat {
#if os(iOS)
        2
#else
        4
#endif
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: detailSpacing) {
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(requiresAttention ? Color.red : Color.secondary)
                }
                if !isNetworkActive {
                    Text("UnObserved").font(.caption).foregroundStyle(.secondary)
                }
                if let deviceID {
                    LabeledContent("Device ID") {
                        Text(deviceID.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    Text("Address is created during network setup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(requiresAttention ? Color.red : (isOnline ? Color.green : Color.secondary.opacity(0.45)))
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(requiresAttention ? "Needs attention" : (!isNetworkActive ? "UnObserved" : (isOnline ? "Online" : "Offline")))
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(requiresAttention ? Color.red : Color.primary)
            }
        }
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
        Section("Network Credentials") {
            Button("Refresh Network Credentials", systemImage: "arrow.clockwise", action: enroll)
                .disabled(isWorking)
            if isWorking {
                ProgressView("Updating Network Credentials…")
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Message")
#if os(macOS)
                MacMessageTextEditor(text: $messageText)
                    .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 200)
                    .accessibilityLabel("Message")
#else
                TextEditor(text: $messageText)
                    .multilineTextAlignment(.leading)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 160, alignment: .leading)
                    .accessibilityLabel("Message")
#endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

#if os(macOS)
private struct MacMessageTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        textView.allowsUndo = true
        textView.alignment = .natural
        textView.baseWritingDirection = .natural
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
#endif

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
                    systemImage: "tray.and.arrow.up",
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
