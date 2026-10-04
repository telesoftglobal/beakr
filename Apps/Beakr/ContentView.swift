import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model: MessageComposerModel
    @State private var bootstrap: NodeBootstrapModel

    init() {
        _model = State(initialValue: .unconfigured())
        _bootstrap = State(initialValue: NodeBootstrapModel())
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
        NavigationStack {
            Form {
                NodeSetupSection(
                    nodeID: bootstrap.nodeID,
                    state: bootstrap.state,
                    statusMessage: bootstrap.statusMessage
                )
                MessageStatusSection(statusMessage: model.statusMessage)
                MessageComposerSection(
                    destinationText: $model.destinationText,
                    messageText: $model.messageText,
                    canSend: model.canSend,
                    send: {
                        Task {
                            await model.send()
                        }
                    }
                )
                OutgoingMessagesSection(messages: model.outgoingMessages)
            }
            .navigationTitle("Messages")
            .task {
                await bootstrap.start()
            }
        }
    }
}

private struct NodeSetupSection: View {
    let nodeID: UUID?
    let state: NodeBootstrapState
    let statusMessage: String

    var body: some View {
        Section("This Device") {
            Label(statusMessage, systemImage: state.systemImage)
                .foregroundStyle(state == .failed ? .red : .secondary)

            if let nodeID {
                LabeledContent("Node ID", value: nodeID.uuidString.lowercased())
                    .textSelection(.enabled)
            }
        }
    }
}

private extension NodeBootstrapState {
    var systemImage: String {
        switch self {
        case .starting:
            "key.horizontal"
        case .needsConfiguration:
            "gear.badge"
        case .identityReady:
            "checkmark.shield"
        case .failed:
            "exclamationmark.shield"
        }
    }
}

private struct MessageStatusSection: View {
    let statusMessage: String

    var body: some View {
        Section("Synchronization") {
            Label(statusMessage, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.secondary)
        }
    }
}

private struct MessageComposerSection: View {
    @Binding var destinationText: String
    @Binding var messageText: String
    let canSend: Bool
    let send: () -> Void

    var body: some View {
        Section("New Message") {
            TextField("Destination Node ID", text: $destinationText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Destination Node ID")

            TextField("Message", text: $messageText, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityLabel("Message")

            Button("Queue Message", systemImage: "paperplane", action: send)
                .disabled(!canSend)
        }
    }
}

private struct OutgoingMessagesSection: View {
    let messages: [OutgoingMessage]

    var body: some View {
        Section("Outgoing") {
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
                        destination: message.destination,
                        state: message.state
                    )
                }
            }
        }
    }
}

private struct OutgoingMessageRow: View {
    let messageBody: String
    let destination: UUID
    let state: MessageDeliveryState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(messageBody)
                .lineLimit(3)

            Text(destination.uuidString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Label(state.title, systemImage: state.systemImage)
                .font(.caption)
                .foregroundStyle(state.color)
        }
    }
}

private extension MessageDeliveryState {
    var title: LocalizedStringKey {
        switch self {
        case .sending:
            "Queueing"
        case .queued:
            "Queued"
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
        case .failed:
            .orange
        }
    }
}

#Preview {
    ContentView()
}
