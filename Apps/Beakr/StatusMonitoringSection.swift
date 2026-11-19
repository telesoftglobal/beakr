import SwiftUI
import BeakrNetCore

struct StatusMonitoringSection: View {
    let profileID: NetworkProfileID
    let peerID: UUID
    let bootstrap: NodeBootstrapModel
    @State private var owner = UUID()
    @State private var monitor: StatusMonitor?
    @State private var store: SharedStatusPermissionStore?
    @State private var permission = SharedStatusPermissionState()
    @State private var state = MonitorViewState()
    @State private var error: String?
    @State private var busy = false
    @State private var command: Task<Void, Never>?
    @State private var generation = UUID()

    private var peer: NodeID { NodeID(rawValue: peerID) }
    private var observationID: String { "\(profileID.rawValue)-\(peerID)-\(bootstrap.sharedStatusRevision)" }
    private var watchingPeer: Bool { state.peer == peer && state.owner != nil }
    private var ownsSession: Bool { watchingPeer && state.owner == owner }

    var body: some View {
        Section("Periodic Status") {
            Toggle("Allow This Device to Monitor My Status", isOn: Binding(
                get: { permission.sharing }, set: changeSharing
            ))
            .disabled(store == nil || busy || (!permission.sharing && monitor == nil))
            Text("Shares the same limited status every two seconds while connected. This permission is separate from one-time status requests.")
                .font(.caption).foregroundStyle(.secondary)
            if permission.needsConfirmation || permission.saveFailed {
                Text("Monitoring permission needs recovery. Save it off before enabling it again.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save Monitoring Off") { changeSharing(false) }
                    .disabled(store == nil || busy)
            }
            if ownsSession {
                Button("Stop Monitoring") {
                    guard let monitor else { return }
                    command?.cancel()
                    command = Task { await monitor.stop(owner: owner) }
                }
            } else if state.owner != nil {
                Text(watchingPeer ? "Monitoring is controlled by another view." : "Another device is being monitored.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Start Monitoring This Device") { start() }
                    .disabled(monitor == nil || busy)
            }
            if state.peer == peer {
                Text(phaseTitle)
                    .foregroundStyle(state.phase == .permissionWithdrawn ? Color.orange : Color.secondary)
                if let snapshot = state.snapshot {
                    LabeledContent("Beakr Version", value: snapshot.applicationVersion)
                    LabeledContent("Runtime") { Text(runtimeTitle(snapshot.runtimeState)) }
                    LabeledContent("Connected Devices", value: snapshot.authenticatedPeerCount.formatted())
                    LabeledContent("Sampled on Remote Device") {
                        Text(snapshot.sampledAt, format: .dateTime.hour().minute().second())
                    }
                    if state.owner != nil, let age = state.ageSeconds {
                        Text("Received \(age) seconds ago").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            Text("Monitoring stops when you close this view or disconnect. Start again after reconnecting. A sample already in flight may arrive after sharing is turned off.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: observationID) {
            let token = UUID()
            let sessionOwner = UUID()
            owner = sessionOwner
            generation = token
            monitor = nil
            busy = false
            state = MonitorViewState()
            let runtime = await bootstrap.sharedStatusRuntime(for: profileID)
            guard !Task.isCancelled, generation == token, let service = await runtime?.monitoring else { return }
            monitor = service
            await withTaskCancellationHandler {
                for await update in await service.updates() {
                    guard !Task.isCancelled, generation == token else { break }
                    // Active sessions remain visible across views. Terminal notices
                    // and their stale sample belong only to the initiating visit.
                    state = update.owner != nil || update.presentationOwner == sessionOwner
                        ? update : MonitorViewState()
                }
                await service.stop(owner: sessionOwner)
            } onCancel: {
                Task { await service.stop(owner: sessionOwner) }
            }
        }
        .task(id: "\(profileID.rawValue)-\(peerID)") {
            store = nil
            permission = SharedStatusPermissionState()
            do {
                let loaded = try await bootstrap.sharedStatusPermissions(for: profileID, operation: .monitor)
                guard !Task.isCancelled else { return }
                store = loaded
                for await update in await loaded.updates(for: peer) {
                    guard !Task.isCancelled else { return }
                    permission = update
                }
            } catch {
                if !Task.isCancelled { self.error = String(localized: "Monitoring permissions could not be loaded.") }
            }
        }
        .onDisappear {
            generation = UUID()
            command?.cancel()
            let sessionOwner = owner
            if let monitor { Task { await monitor.stop(owner: sessionOwner) } }
        }
    }

    private var phaseTitle: LocalizedStringKey {
        switch state.phase {
        case .stopped: "Monitoring stopped — last sample is stale."
        case .starting: "Starting monitoring…"
        case .monitoring: state.snapshot == nil ? "Waiting for the first sample…" : "Monitoring"
        case .stale: "Status is stale."
        case .disconnected: "Disconnected — start again after reconnecting."
        case .permissionWithdrawn: "Monitoring permission withdrawn — last sample is stale."
        case .denied: "This device has not allowed monitoring."
        case .failed: "Monitoring ended — request or lease expired."
        }
    }

    private func runtimeTitle(_ value: SharedStatusSnapshot.RuntimeState) -> LocalizedStringKey {
        switch value {
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    private func start() {
        guard let monitor, !busy else { return }
        let token = generation
        let sessionOwner = owner
        error = nil
        command = Task {
            do { try await monitor.start(peer: peer, owner: sessionOwner) }
            catch { if generation == token { self.error = String(localized: "Monitoring could not start. Check the connection or stop the existing session.") } }
        }
    }

    private func changeSharing(_ enabled: Bool) {
        guard let store, !busy else { return }
        let revision = permission.revision
        let service = monitor
        let token = generation
        error = nil
        busy = true
        command = Task {
            do {
                if enabled {
                    guard let service else { throw SharedStatusPermissionError.unavailable }
                    try await service.setSharing(true, peer: peer, revision: revision)
                } else {
                    try await store.setSharing(false, peer: peer, identity: nil, expectedRevision: revision)
                }
            } catch {
                if generation == token { self.error = String(localized: "Monitoring permission could not be changed. Verify membership and save monitoring off before retrying.") }
            }
            busy = false
        }
    }
}
