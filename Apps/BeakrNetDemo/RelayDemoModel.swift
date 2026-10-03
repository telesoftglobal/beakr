import BeakrNetCore
import BeakrNetRelayTransport
import BeakrNetSecurity
import Foundation
import Observation

@MainActor
@Observable
final class RelayDemoModel {
    var relayHost = "127.0.0.1"
    var relayPort = "7878"
    var preSharedKeyBase64 = ""
    var credentialJSON = ""
    var destinationNodeID = "" {
        didSet {
            configurationStore.saveDestinationNodeID(destinationNodeID)
        }
    }
    var peerName = ""
    private(set) var savedPeers: [SavedPeer] = []
    var message = "ping"
    private(set) var nodeID = "Unavailable"
    private(set) var publicKeyBase64 = ""
    private(set) var status = "Offline"
    private(set) var events: [DemoEvent] = []
    private(set) var lastConnectedAt: Date?
    private(set) var lastDisconnectedAt: Date?
    private(set) var lastMessageAt: Date?
    private(set) var reconnectionAttemptCount = 0
    private(set) var sentMessageCount = 0
    private(set) var receivedMessageCount = 0
    private(set) var credentialExpiresAt: Date?

    var isConnected: Bool {
        transport != nil
    }

    private var currentConfiguration: DemoConfiguration {
        DemoConfiguration(
            relayHost: relayHost,
            relayPort: relayPort,
            preSharedKeyBase64: preSharedKeyBase64,
            credentialJSON: credentialJSON,
            destinationNodeID: destinationNodeID
        )
    }

    var canConnect: Bool {
        !isConnected && !preSharedKeyBase64.isEmpty && !credentialJSON.isEmpty
    }

    var canSend: Bool {
        isConnected && UUID(uuidString: destinationNodeID) != nil && !message.isEmpty
    }

    var canSavePeer: Bool {
        UUID(uuidString: destinationNodeID) != nil && !peerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedPeerName: String? {
        savedPeers.first {
            $0.nodeID.caseInsensitiveCompare(destinationNodeID) == .orderedSame
        }?.name
    }

    private var identity: NodeIdentity?
    private var transport: RelayTransport?
    private var receiveTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private let sessionID = SessionID()
    private let configurationStore = DemoConfigurationStore()

    init() {
        do {
            let configuration = try configurationStore.load()
            relayHost = configuration.relayHost
            relayPort = configuration.relayPort
            preSharedKeyBase64 = configuration.preSharedKeyBase64
            credentialJSON = configuration.credentialJSON
            destinationNodeID = configuration.destinationNodeID
            updateCredentialExpiration(from: configuration.credentialJSON)
        } catch {
            status = "Configuration error: \(error.localizedDescription)"
        }
        savedPeers = configurationStore.loadSavedPeers()

        do {
            let identity = try KeychainNodeIdentityStore(service: "net.beakr.demo").loadOrCreate()
            self.identity = identity
            nodeID = identity.nodeID.rawValue.uuidString.lowercased()
            publicKeyBase64 = identity.publicKeyRepresentation.base64EncodedString()
        } catch {
            status = "Identity error: \(error.localizedDescription)"
        }
    }

    func importPeer(from enrollmentString: String) throws {
        let enrollment = try NodeEnrollmentPayload.decodeAndValidate(enrollmentString)
        destinationNodeID = enrollment.nodeID.lowercased()
        peerName = enrollment.displayName
        saveCurrentPeer()
    }

    func selectPeer(_ peer: SavedPeer) {
        destinationNodeID = peer.nodeID
        peerName = peer.name
    }

    func saveCurrentPeer() {
        guard let nodeUUID = UUID(uuidString: destinationNodeID) else { return }
        let normalizedNodeID = nodeUUID.uuidString.lowercased()
        let normalizedName = peerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        if let index = savedPeers.firstIndex(where: { $0.nodeID == normalizedNodeID }) {
            savedPeers[index].name = normalizedName
        } else {
            savedPeers.append(SavedPeer(nodeID: normalizedNodeID, name: normalizedName))
        }
        savedPeers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        destinationNodeID = normalizedNodeID
        peerName = normalizedName
        persistSavedPeers(successMessage: "Peer saved")
    }

    func deletePeer(_ peer: SavedPeer) {
        savedPeers.removeAll { $0.id == peer.id }
        if destinationNodeID.caseInsensitiveCompare(peer.nodeID) == .orderedSame {
            peerName = ""
        }
        persistSavedPeers(successMessage: "Peer removed")
    }

    func saveConfiguration() {
        do {
            try configurationStore.save(currentConfiguration)
            record("Configuration saved", kind: .status)
        } catch {
            record("Could not save configuration: \(error.localizedDescription)", kind: .error)
        }
    }

    func clearSavedConfiguration() {
        guard !isConnected else { return }

        do {
            try configurationStore.clear()
            relayHost = "127.0.0.1"
            relayPort = "7878"
            preSharedKeyBase64 = ""
            credentialJSON = ""
            destinationNodeID = ""
            record("Saved configuration cleared", kind: .status)
        } catch {
            record("Could not clear configuration: \(error.localizedDescription)", kind: .error)
        }
    }

    func connect() async {
        guard let identity,
              let port = UInt16(relayPort),
              let preSharedKey = Data(base64Encoded: preSharedKeyBase64) else {
            record("Connection settings are invalid", kind: .error)
            return
        }

        do {
            let credential = try JSONDecoder().decode(
                NodeCredential.self,
                from: Data(credentialJSON.utf8)
            )
            updateCredentialExpiration(from: credential)
            let configuration = try RelayTransportConfiguration(
                host: relayHost,
                port: port,
                preSharedKey: preSharedKey,
                identity: identity,
                credential: credential
            )
            let transport = RelayTransport(configuration: configuration)
            status = "Connecting"
            try await transport.connect()
            self.transport = transport
            status = "Online"
            lastConnectedAt = .now
            record("Authenticated with relay", kind: .status)
            saveConfiguration()
            startReceiving(from: transport)
            startDiagnostics(for: transport)
        } catch {
            status = "Offline"
            record(error.localizedDescription, kind: .error)
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        diagnosticTask?.cancel()
        receiveTask = nil
        diagnosticTask = nil
        await transport?.close()
        transport = nil
        status = "Offline"
        lastDisconnectedAt = .now
        record("Disconnected", kind: .status)
    }

    func sendPing() async {
        guard let identity,
              let transport,
              let destinationUUID = UUID(uuidString: destinationNodeID) else {
            return
        }

        sequenceNumber += 1
        let envelope = BeakrNetEnvelope(
            sessionID: sessionID,
            sourceNodeID: identity.nodeID,
            destinationNodeID: NodeID(rawValue: destinationUUID),
            sequenceNumber: sequenceNumber,
            payloadType: "net.beakr.demo.ping",
            payload: Data(message.utf8)
        )

        do {
            try await transport.send(envelope)
            sentMessageCount += 1
            lastMessageAt = .now
            record("Sent #\(sequenceNumber): \(message)", kind: .sent)
        } catch {
            record(error.localizedDescription, kind: .error)
        }
    }

    private func startReceiving(from transport: RelayTransport) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled, let envelope = await transport.receive() {
                guard let self else { return }
                let payload = String(decoding: envelope.payload, as: UTF8.self)
                receivedMessageCount += 1
                lastMessageAt = .now
                record("Received #\(envelope.sequenceNumber): \(payload)", kind: .received)
            }
        }
    }

    private func startDiagnostics(for transport: RelayTransport) {
        diagnosticTask = Task { [weak self] in
            while !Task.isCancelled {
                let relayState = await transport.state
                self?.applyRelayState(relayState)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func applyRelayState(_ relayState: RelayTransportState) {
        let nextStatus = relayState.label
        guard nextStatus != status else { return }

        let previousStatus = status
        switch relayState {
        case .ready:
            lastConnectedAt = .now
        case .waitingToReconnect:
            reconnectionAttemptCount += 1
            lastDisconnectedAt = .now
        case .idle, .closed:
            lastDisconnectedAt = .now
        case .connecting, .authenticating:
            break
        }
        status = nextStatus
        record("\(previousStatus) → \(nextStatus)", kind: .status)
    }

    private func updateCredentialExpiration(from credentialJSON: String) {
        guard let credential = try? JSONDecoder().decode(
            NodeCredential.self,
            from: Data(credentialJSON.utf8)
        ) else {
            credentialExpiresAt = nil
            return
        }
        updateCredentialExpiration(from: credential)
    }

    private func updateCredentialExpiration(from credential: NodeCredential) {
        credentialExpiresAt = Date(
            timeIntervalSince1970: Double(credential.claims.expiresAtMilliseconds) / 1_000
        )
    }

    private func persistSavedPeers(successMessage: String) {
        do {
            try configurationStore.saveSavedPeers(savedPeers)
            record(successMessage, kind: .status)
        } catch {
            record("Could not save peers: \(error.localizedDescription)", kind: .error)
        }
    }

    private func record(_ text: String, kind: DemoEvent.Kind) {
        events.insert(DemoEvent(text: text, kind: kind), at: 0)
    }
}

struct DemoEvent: Identifiable {
    enum Kind {
        case status
        case sent
        case received
        case error
    }

    let id = UUID()
    let date = Date()
    let text: String
    let kind: Kind
}

private extension RelayTransportState {
    var label: String {
        switch self {
        case .idle: "Offline"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .ready: "Online"
        case .waitingToReconnect(let attempt): "Reconnecting (\(attempt))"
        case .closed: "Offline"
        }
    }
}
