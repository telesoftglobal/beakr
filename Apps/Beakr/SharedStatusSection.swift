import SwiftUI
import BeakrNetCore
import BeakrNetData

struct SharedStatusSection: View {
    let profileID: NetworkProfileID
    let peerID: UUID
    let peerName: String
    let isOnline: Bool
    let bootstrap: NodeBootstrapModel
    var showsHeader = true
    @State private var isPresented = false
    @State private var permissionStore: SharedStatusPermissionStore?
    @State private var permission = SharedStatusPermissionState()
    @State private var permissionGeneration = UUID()
    @State private var permissionFailure: SharedStatusPermissionError?
    @State private var runtime: SharedStatusRuntime?
    @State private var availability = SharedStatusAvailability.unavailable
    @State private var result: SharedStatusResult?
    @State private var failure: SharedStatusError?
    @State private var requestTask: Task<Void, Never>?
    @State private var sharingBusy = false
    @State private var viewGeneration = UUID()
    @State private var requestGeneration = UUID()

    private var observationID: String { "\(profileID.rawValue)-\(peerID)-\(isOnline)-\(bootstrap.sharedStatusRevision)" }

    var body: some View {
        Section {
            SharedStatusControls(availability: availability, permission: permission, permissionFailure: permissionFailure,
                                     permissionLoaded: permissionStore != nil, canEnableSharing: runtime != nil, result: result, failure: failure,
                                     isRequesting: requestTask != nil, sharingBusy: sharingBusy,
                                     changeSharing: changeSharing, request: request, cancel: { requestTask?.cancel() })
        } header: {
            if showsHeader {
                HStack {
                    Text("Shared Status")
                    Spacer()
                    SharedStatusMenu(peerName: peerName, isPresented: $isPresented) {
                        SharedStatusControls(availability: availability, permission: permission, permissionFailure: permissionFailure,
                                     permissionLoaded: permissionStore != nil, canEnableSharing: runtime != nil, result: result, failure: failure,
                                             isRequesting: requestTask != nil, sharingBusy: sharingBusy,
                                             changeSharing: changeSharing, request: request, cancel: { requestTask?.cancel() })
                    }
                }
            }
        }
        .task(id: "\(profileID.rawValue)-\(peerID)") {
            let generation = UUID()
            permissionGeneration = generation
            permissionStore = nil
            permission = SharedStatusPermissionState()
            permissionFailure = nil
            sharingBusy = false
            do {
                let store = try await bootstrap.sharedStatusPermissions(for: profileID)
                guard !Task.isCancelled, permissionGeneration == generation else { return }
                permissionStore = store
                for await state in await store.updates(for: NodeID(rawValue: peerID)) {
                    guard !Task.isCancelled, permissionGeneration == generation else { return }
                    permission = state
                }
            } catch {
                if !Task.isCancelled, permissionGeneration == generation { permissionFailure = error as? SharedStatusPermissionError ?? .invalidStore }
            }
        }
        .task(id: observationID) {
            let generation = UUID()
            viewGeneration = generation
            requestTask?.cancel()
            requestGeneration = UUID()
            requestTask = nil
            runtime = nil
            availability = .unavailable
            result = nil
            failure = nil
            guard let service = await bootstrap.sharedStatusRuntime(for: profileID),
                  !Task.isCancelled else { return }
            runtime = service
            for await update in await service.updates(for: NodeID(rawValue: peerID)) {
                guard !Task.isCancelled, viewGeneration == generation else { return }
                if availability.bindingID != update.bindingID {
                    requestTask?.cancel()
                    requestGeneration = UUID()
                    requestTask = nil
                    result = nil
                    failure = nil
                }
                availability = update
            }
        }
        .onDisappear {
            permissionGeneration = UUID()
            viewGeneration = UUID()
            requestGeneration = UUID()
            requestTask?.cancel()
            requestTask = nil
        }
        StatusMonitoringSection(profileID: profileID, peerID: peerID, bootstrap: bootstrap)
    }

    private func changeSharing(_ enabled: Bool) {
        guard let permissionStore, !sharingBusy else { return }
        let revision = permission.revision
        let generation = permissionGeneration
        let service = runtime
        sharingBusy = true
        permissionFailure = nil
        Task {
            do {
                if enabled {
                    guard let service else { throw SharedStatusPermissionError.unavailable }
                    try await service.setSavedSharing(true, peer: NodeID(rawValue: peerID), expectedRevision: revision)
                } else {
                    try await permissionStore.setSharing(false, peer: NodeID(rawValue: peerID), identity: nil,
                                                         expectedRevision: revision)
                }
            } catch {
                if permissionGeneration == generation {
                    permissionFailure = error as? SharedStatusPermissionError ?? .persistenceFailed
                }
            }
            if permissionGeneration == generation { sharingBusy = false }
        }
    }

    private func request() {
        guard requestTask == nil, let runtime, let bindingID = availability.bindingID else { return }
        let generation = viewGeneration
        let requestID = UUID()
        requestGeneration = requestID
        failure = nil
        result = nil
        requestTask = Task {
            do {
                let reply = try await runtime.request(peer: NodeID(rawValue: peerID), bindingID: bindingID)
                if generation == viewGeneration, requestGeneration == requestID, availability.bindingID == bindingID { result = reply }
            } catch {
                if generation == viewGeneration, requestGeneration == requestID, availability.bindingID == bindingID {
                    failure = error as? SharedStatusError ?? .unavailable
                }
            }
            if generation == viewGeneration, requestGeneration == requestID { requestTask = nil }
        }
    }
}

/// Both presentations render the owning section's state and invoke the same actions.
private struct SharedStatusControls: View {
    let availability: SharedStatusAvailability
    let permission: SharedStatusPermissionState
    let permissionFailure: SharedStatusPermissionError?
    let permissionLoaded: Bool
    let canEnableSharing: Bool
    let result: SharedStatusResult?
    let failure: SharedStatusError?
    let isRequesting: Bool
    let sharingBusy: Bool
    let changeSharing: (Bool) -> Void
    let request: () -> Void
    let cancel: () -> Void

    var body: some View {
        Toggle("Share My Status with This Device", isOn: Binding(
            get: { permission.sharing },
            set: { enabled in changeSharing(enabled) }
        ))
        .disabled(!permissionLoaded || sharingBusy || (!permission.sharing && !canEnableSharing))

        Text("Allow this device to read my status: Beakr’s version, runtime state and connected-device count. Your choice is saved for this membership and device. Access still requires a currently authorized connection.")
            .font(.caption).foregroundStyle(.secondary)

        if !isRequesting {
            Button("Request This Device’s Status", action: request)
                .disabled(availability.bindingID == nil)
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Requesting Status…")
                Button("Cancel") { cancel() }
            }
        }

        if availability.bindingID == nil {
            Text("This device is currently unavailable for status requests. Saved sharing can be changed while it is offline.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !canEnableSharing {
            Text("To enable sharing, select this network and start Beakr’s network connection. This device can remain offline.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if permission.needsConfirmation {
            Text("Sharing needs confirmation after an interrupted session. Enable sharing again with valid membership, or clear the saved choice.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if permission.saveFailed || permission.needsConfirmation {
            Button("Save Sharing Off") { changeSharing(false) }
                .disabled(!permissionLoaded || sharingBusy)
        }
        if permission.saveFailed {
            Text("Sharing is blocked because its settings could not be saved. Save sharing off before enabling it again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let permissionFailure { Text(permissionFailure.statusDescription).foregroundStyle(.secondary) }
        if let failure { Text(failure.statusDescription).foregroundStyle(.secondary) }
        if let result {
            LabeledContent("Beakr Version", value: result.snapshot.applicationVersion)
            LabeledContent("Runtime") { Text(result.snapshot.runtimeState.statusTitle) }
            LabeledContent("Connected Devices", value: result.snapshot.authenticatedPeerCount.formatted())
            LabeledContent("Sampled on Remote Device") {
                Text(result.snapshot.sampledAt, format: .dateTime.year().month().day().hour().minute().second())
            }
            Text("This is a snapshot, not continuously updated status.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SharedStatusMenu<Controls: View>: View {
    let peerName: String
    @Binding var isPresented: Bool
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        Menu {
            Button("Shared Status…") { isPresented = true }
        } label: {
            Label("Device Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel("Device Actions")
        #if os(macOS)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SharedStatusPresentation(peerName: peerName, controls: controls)
                .frame(width: 420, height: 520)
        }
        #else
        .sheet(isPresented: $isPresented) {
            SharedStatusPresentation(peerName: peerName, controls: controls)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
    }
}

private struct SharedStatusPresentation<Controls: View>: View {
    let peerName: String
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Shared Status").font(.headline)
                    Text(peerName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Form {
                Section { controls() }
            }
            .formStyle(.grouped)
        }
    }
}

extension SharedStatusSnapshot.RuntimeState {
    var statusTitle: LocalizedStringResource {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }
}

extension SharedStatusError {
    var statusDescription: LocalizedStringResource {
        switch self {
        case .unauthorized: "Status access is not enabled."
        case .remote(.unauthorized): "This device hasn’t allowed you to read its status."
        case .timedOut, .remote(.deadlineExceeded): "No status reply arrived in time. The other device may not support this service."
        case .cancelled: "Status request cancelled."
        case .invalidated: "The connection changed. Request status again after reconnecting."
        case .unavailable: "This device is unavailable."
        case .busy, .remote(.resourceLimit): "A status request is already in progress. Try again shortly."
        case .invalidResponse: "The device returned an invalid status reply."
        case .remote: "The device could not provide its status."
        }
    }
}


extension SharedStatusPermissionError {
    var statusDescription: LocalizedStringResource {
        switch self {
        case .invalidStore: "Saved sharing settings could not be opened. Sharing remains blocked."
        case .persistenceFailed: "Sharing settings could not be saved. Sharing remains blocked."
        case .staleRevision: "Sharing settings changed in another operation. Review the current choice and try again."
        case .unavailable: "Enabling sharing requires the selected network to be running with verified, valid membership for both devices."
        }
    }
}
