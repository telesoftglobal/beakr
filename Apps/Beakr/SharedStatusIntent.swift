import AppIntents
import Foundation
import OSLog
import BeakrNetCore
import BeakrNetData

/// Persisted shortcut identity uses network/node identity, never a name or runtime binding.
nonisolated struct StatusDeviceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Beakr Device" }
    static var defaultQuery: StatusDeviceQuery { StatusDeviceQuery() }
    let id: String
    let name: String
    let networkName: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(networkName)")
    }

    init(networkID: NetworkID, nodeID: NodeID, name: String, networkName: String) {
        id = "\(networkID.rawValue.uuidString)/\(nodeID.rawValue.uuidString)"
        self.name = name
        self.networkName = networkName
    }
}

nonisolated struct StatusIntentSelection: Sendable {
    let profileID: NetworkProfileID
    let networkID: NetworkID
    let localNodeID: NodeID
    let devices: [StatusDeviceEntity]
}

nonisolated protocol StatusIntentRuntime: Sendable {
    func availability(for peer: NodeID) async -> SharedStatusAvailability
    func request(peer: NodeID, bindingID: UUID) async throws -> SharedStatusResult
}
extension SharedStatusRuntime: StatusIntentRuntime {}

nonisolated enum StatusIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case notReady, invalidTarget, selectionChanged
    case service(SharedStatusError)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Open Beakr and wait for the selected network to connect, then try again."
        case .invalidTarget: "Choose a remote device on Beakr’s currently selected network."
        case .selectionChanged: "The selected network or device changed. Request status again."
        case .service(.unauthorized), .service(.remote(.unauthorized)): "This device hasn’t allowed you to read its status."
        case .service(.busy), .service(.remote(.resourceLimit)): "A status request is already in progress. Try again shortly."
        case .service(.timedOut), .service(.remote(.deadlineExceeded)): "No status reply arrived in time."
        case .service(.cancelled): "Status request cancelled."
        case .service(.invalidated): "The connection changed. Request status again after reconnecting."
        case .service(.unavailable): "This device is unavailable."
        case .service(.invalidResponse): "The device returned an invalid status reply."
        case .service(.remote): "The device could not provide its status."
        }
    }
}

/// Trusted composition exposes only lookup and read; no sharing or network-switch capability.
@MainActor
final class StatusIntentAdapter {
    private let readinessTimeout: Duration
    private let selection: () -> StatusIntentSelection?
    private let runtime: (NetworkProfileID) async -> (any StatusIntentRuntime)?

    init(readinessTimeout: Duration = .seconds(5), selection: @escaping () -> StatusIntentSelection?,
         runtime: @escaping (NetworkProfileID) async -> (any StatusIntentRuntime)?) {
        self.readinessTimeout = max(.zero, readinessTimeout)
        self.selection = selection
        self.runtime = runtime
    }

    convenience init(bootstrap: NodeBootstrapModel) {
        self.init(selection: { [weak bootstrap] in
            guard let bootstrap, let profileID = bootstrap.profileID,
                  let session = bootstrap.networkSessions.first(where: { $0.id.rawValue == profileID && $0.isSelected }) else { return nil }
            let profile = session.profile
            return StatusIntentSelection(
                profileID: profile.id, networkID: profile.networkID, localNodeID: profile.localNodeID,
                devices: Self.pickerMembers(live: bootstrap.networkMembers, saved: bootstrap.savedMemberships[profile.id])
                    .filter { $0.id != profile.localNodeID.rawValue }.map {
                    StatusDeviceEntity(networkID: profile.networkID, nodeID: NodeID(rawValue: $0.id),
                                       name: $0.displayName, networkName: profile.displayName)
                }
            )
        }, runtime: { [weak bootstrap] profile in
            await bootstrap?.sharedStatusRuntime(for: profile)
        })
    }

    /// Saved membership is a picker projection only; request authorization stays live.
    static func pickerMembers(live: [NetworkMemberSummary], saved: SavedNetworkMembership?) -> [NetworkMemberSummary] {
        if !live.isEmpty { return live }
        guard let saved, saved.state != .unavailable else { return [] }
        return saved.members
    }

    func devices() throws -> [StatusDeviceEntity] {
        let selected = selection()
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        Logger(subsystem: "net.beakr.app", category: "StatusIntent").info(
            "[STATUS-QUERY] platform=\(platform, privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier) selected=\(selected != nil) count=\(selected?.devices.count ?? 0)"
        )
        guard let selected else { throw StatusIntentError.notReady }
        return selected.devices
    }

    func request(id: String) async throws -> (StatusDeviceEntity, SharedStatusResult) {
        do {
            try Task.checkCancellation()
            guard let selected = selection() else { throw StatusIntentError.notReady }
            let components = id.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, let network = UUID(uuidString: String(components[0])),
                  let peerUUID = UUID(uuidString: String(components[1])),
                  network == selected.networkID.rawValue, peerUUID != selected.localNodeID.rawValue,
                  let device = selected.devices.first(where: { $0.id == id }) else { throw StatusIntentError.invalidTarget }
            let peer = NodeID(rawValue: peerUUID)
            let (service, bindingID) = try await readyRuntime(selected, peer: peer, id: id)
            let result = try await service.request(peer: peer, bindingID: bindingID)
            try Task.checkCancellation()
            try validateSelection(selected, id: id)
            guard result.binding.networkID == selected.networkID,
                  result.binding.localNodeID == selected.localNodeID,
                  result.binding.peerNodeID == peer else { throw SharedStatusError.invalidResponse }
            return (device, result)
        } catch let error as StatusIntentError { throw error }
        catch is CancellationError { throw StatusIntentError.service(.cancelled) }
        catch let error as SharedStatusError { throw StatusIntentError.service(error) }
        catch { throw StatusIntentError.service(.unavailable) }
    }

    /// Observe the existing foreground startup; never initiate networking or retry a request.
    private func readyRuntime(_ selected: StatusIntentSelection, peer: NodeID, id: String) async throws
        -> (any StatusIntentRuntime, UUID) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)
        var firstCheck = true
        while true {
            try Task.checkCancellation()
            try validateSelection(selected, id: id)
            guard firstCheck || clock.now < deadline else { throw StatusIntentError.notReady }
            firstCheck = false
            let service = await runtime(selected.profileID)
            try Task.checkCancellation()
            try validateSelection(selected, id: id)
            if let service {
                let availability = await service.availability(for: peer)
                try Task.checkCancellation()
                try validateSelection(selected, id: id)
                if let bindingID = availability.bindingID {
                    guard readinessTimeout == .zero || clock.now < deadline else { throw StatusIntentError.notReady }
                    return (service, bindingID)
                }
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw StatusIntentError.notReady }
            try await clock.sleep(for: min(.milliseconds(100), remaining))
        }
    }

    private func validateSelection(_ expected: StatusIntentSelection, id: String) throws {
        guard let current = selection(), current.profileID == expected.profileID,
              current.networkID == expected.networkID, current.localNodeID == expected.localNodeID,
              current.devices.contains(where: { $0.id == id }) else { throw StatusIntentError.selectionChanged }
    }
}

nonisolated struct StatusDeviceQuery: EntityStringQuery {
    @Dependency private var adapter: StatusIntentAdapter

    func entities(for identifiers: [String]) async throws -> [StatusDeviceEntity] {
        let devices = try await adapter.devices()
        return identifiers.compactMap { id in devices.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [StatusDeviceEntity] { try await adapter.devices() }

    func entities(matching string: String) async throws -> [StatusDeviceEntity] {
        try await adapter.devices().filter {
            $0.name.localizedStandardContains(string) || $0.networkName.localizedStandardContains(string)
        }
    }
}

nonisolated struct RequestDeviceStatusIntent: AppIntent, CancellableIntent {
    static var title: LocalizedStringResource { "Request Device Status" }
    static var description: IntentDescription { "Read a remote device’s shared status on Beakr’s selected network. The remote device must allow sharing." }
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    static var parameterSummary: some ParameterSummary { Summary("Request status from \(\.$device)") }

    @Parameter(title: "Device") var device: StatusDeviceEntity
    @Dependency private var adapter: StatusIntentAdapter

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let task = Task { try await adapter.request(id: device.id) }
        let (target, reply) = try await withTaskCancellationHandler {
            try await withIntentCancellationHandler {
                try await task.value
            } onCancel: { _ in task.cancel() }
        } onCancel: { task.cancel() }
        let state = String(localized: reply.snapshot.runtimeState.statusTitle)
        let sampled = reply.snapshot.sampledAt.formatted(date: .abbreviated, time: .standard)
        let text = String(localized: "\(target.name) on \(target.networkName): Beakr \(reply.snapshot.applicationVersion), runtime \(state), \(reply.snapshot.authenticatedPeerCount) connected devices. Sampled \(sampled).")
        return .result(value: text, dialog: "\(text)")
    }
}
