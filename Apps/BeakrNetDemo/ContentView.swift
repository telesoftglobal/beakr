import SwiftUI

struct ContentView: View {
    @State private var model = RelayDemoModel()

    var body: some View {
        NavigationStack {
            Form {
                IdentitySection(
                    status: model.status,
                    nodeID: model.nodeID,
                    publicKey: model.publicKeyBase64
                )
#if os(iOS)
                EnrollmentSection(model: model)
#endif
                DiagnosticsSection(
                    status: model.status,
                    lastConnectedAt: model.lastConnectedAt,
                    lastDisconnectedAt: model.lastDisconnectedAt,
                    lastMessageAt: model.lastMessageAt,
                    reconnectionAttemptCount: model.reconnectionAttemptCount,
                    sentMessageCount: model.sentMessageCount,
                    receivedMessageCount: model.receivedMessageCount,
                    credentialExpiresAt: model.credentialExpiresAt
                )
                LifecycleSection(model: model, lifecycle: model.lifecycle)
                RelaySection(model: model)
                PeerSection(model: model)
                PingSection(model: model)
                EventSection(events: model.events)
            }
            .navigationTitle("BeakrNet Demo")
        }
    }
}

private struct LifecycleSection: View {
    @Bindable var model: RelayDemoModel
    @Bindable var lifecycle: CertificateLifecycleCoordinator

    var body: some View {
        Section("Certificate Lifecycle") {
            TextField("Authority public key (Base64)", text: $model.authorityPublicKeyBase64)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
#endif
                .autocorrectionDisabled()
            TextField("Control-plane HTTPS URL", text: $model.controlPlaneURL)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
                .autocorrectionDisabled()
            LabeledContent("Revocation status", value: lifecycle.status)
            LabeledContent("LAN certificate", value: lifecycle.certificateStatus)
            LifecycleDateRow(label: "Certificate expires", date: lifecycle.certificateExpiresAt)
            LifecycleDateRow(label: "Next renewal", date: lifecycle.nextRenewalAt)
            LifecycleDateRow(label: "Last refresh", date: lifecycle.lastRefreshAt)
            LifecycleDateRow(label: "Next refresh", date: lifecycle.nextRefreshAt)
            if let generation = lifecycle.snapshotGeneration {
                LabeledContent("Snapshot generation") {
                    Text(generation, format: .number.grouping(.never))
                }
            }
            if let lastError = lifecycle.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Save and Start Lifecycle") {
                Task { await model.saveAndRestartLifecycle() }
            }
            Button("Enroll LAN Certificate") {
                Task { await lifecycle.enrollCertificate() }
            }
            .disabled(lifecycle.status == "Not configured")
            Button("Renew LAN Certificate Now") {
                Task { await lifecycle.renewCertificateNow() }
            }
            .disabled(lifecycle.nextRenewalAt == nil)
            Button("Refresh Revocations") {
                Task { await lifecycle.refreshManually() }
            }
            .disabled(lifecycle.status == "Not configured")
        }
    }
}

private struct LifecycleDateRow: View {
    let label: LocalizedStringResource
    let date: Date?

    var body: some View {
        LabeledContent(label) {
            if let date {
                Text(date, style: .relative)
            } else {
                Text("Never")
            }
        }
    }
}

private struct IdentitySection: View {
    let status: String
    let nodeID: String
    let publicKey: String

    var body: some View {
        Section("This Device") {
            LabeledContent("Status", value: status)
            LabeledContent("Node ID") {
                Text(nodeID)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            DisclosureGroup("Enrollment public key") {
                Text(publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private struct DiagnosticsSection: View {
    let status: String
    let lastConnectedAt: Date?
    let lastDisconnectedAt: Date?
    let lastMessageAt: Date?
    let reconnectionAttemptCount: Int
    let sentMessageCount: Int
    let receivedMessageCount: Int
    let credentialExpiresAt: Date?

    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Transport", value: status)
            DiagnosticDateRow(label: "Last connected", date: lastConnectedAt)
            DiagnosticDateRow(label: "Last disconnected", date: lastDisconnectedAt)
            DiagnosticDateRow(label: "Last message", date: lastMessageAt)
            LabeledContent("Reconnect attempts") {
                Text(reconnectionAttemptCount, format: .number)
            }
            LabeledContent("Messages sent") {
                Text(sentMessageCount, format: .number)
            }
            LabeledContent("Messages received") {
                Text(receivedMessageCount, format: .number)
            }
            LabeledContent("Credential expires") {
                if let credentialExpiresAt {
                    Text(
                        credentialExpiresAt,
                        format: .dateTime.year().month().day().hour().minute()
                    )
                } else {
                    Text("Unavailable")
                }
            }
        }
    }
}

private struct DiagnosticDateRow: View {
    let label: LocalizedStringResource
    let date: Date?

    var body: some View {
        LabeledContent(label) {
            if let date {
                Text(date, style: .relative)
            } else {
                Text("Never")
            }
        }
    }
}

private struct RelaySection: View {
    @Bindable var model: RelayDemoModel
    @State private var isShowingClearConfirmation = false

    var body: some View {
        Section("Relay") {
            TextField("Host", text: $model.relayHost)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
#endif
                .autocorrectionDisabled()
            TextField("Port", text: $model.relayPort)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
            SecureField("Pre-shared key (Base64)", text: $model.preSharedKeyBase64)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
#endif
                .autocorrectionDisabled()
            TextField("Credential JSON", text: $model.credentialJSON, axis: .vertical)
                .lineLimit(4...10)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
#endif
                .autocorrectionDisabled()

            if model.isConnected {
                Button("Disconnect", role: .destructive) {
                    Task { await model.disconnect() }
                }
            } else {
                Button("Connect") {
                    Task { await model.connect() }
                }
                .disabled(!model.canConnect)
            }

            Button("Save Configuration") {
                model.saveConfiguration()
            }

            Button("Clear Saved Configuration", role: .destructive) {
                isShowingClearConfirmation = true
            }
            .disabled(model.isConnected)
        }
        .confirmationDialog(
            "Clear saved configuration?",
            isPresented: $isShowingClearConfirmation
        ) {
            Button("Clear Configuration", role: .destructive) {
                model.clearSavedConfiguration()
            }
        } message: {
            Text("The relay host, port, credentials, and destination Node ID will be removed. Your device identity will remain unchanged.")
        }
    }
}

private struct PeerSection: View {
    @Bindable var model: RelayDemoModel

    var body: some View {
        Section("Destination") {
            if model.savedPeers.isEmpty {
                Text("No saved peers. Enter a Node ID and peer name below, then tap Save Peer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(model.savedPeers) { peer in
                        Button(peer.name) {
                            model.selectPeer(peer)
                        }
                    }
                } label: {
                    Label(
                        model.selectedPeerName ?? "Choose Saved Peer",
                        systemImage: "person.2"
                    )
                }
                LabeledContent("Saved peers") {
                    Text(model.savedPeers.count, format: .number)
                }
            }

            TextField("Destination Node ID", text: $model.destinationNodeID)
#if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
#endif
                .autocorrectionDisabled()
            TextField("Peer Name", text: $model.peerName)
            Button(model.selectedPeerName == nil ? "Save Peer" : "Update Saved Peer") {
                model.saveCurrentPeer()
            }
            .disabled(!model.canSavePeer)

            if !model.savedPeers.isEmpty {
                DisclosureGroup("Saved Peers") {
                    ForEach(model.savedPeers) { peer in
                        HStack {
                            Button(peer.name) {
                                model.selectPeer(peer)
                            }
                            Spacer()
                            Button("Remove \(peer.name)", systemImage: "trash", role: .destructive) {
                                model.deletePeer(peer)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
    }
}

private struct PingSection: View {
    @Bindable var model: RelayDemoModel

    var body: some View {
        Section("Ping a Peer") {
            TextField("Message", text: $model.message)
            Button("Send Ping") {
                Task { await model.sendPing() }
            }
            .disabled(!model.canSend)
        }
    }
}

private struct EventSection: View {
    let events: [DemoEvent]

    var body: some View {
        Section("Events") {
            if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "network",
                    description: Text("Connection and ping activity will appear here.")
                )
            } else {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.text)
                        Text(event.date, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
