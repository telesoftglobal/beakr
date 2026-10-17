import Foundation
import Testing
import BeakrNetCore
import BeakrNetTestSupport

@Suite("Bonjour discovery metadata")
struct BonjourDiscoveryMetadataTests {
    @Test("Friendly names round trip and remain optional")
    func friendlyNameRoundTrip() throws {
        let named = BonjourDiscoveryMetadata(
            nodeIDHint: NodeID(rawValue: UUID()),
            advertisementNonce: Data(repeating: 7, count: 32),
            displayName: "Alice’s iPhone"
        )

        #expect(try BonjourMetadataParser.parse(named.txtRecord).displayName == "Alice’s iPhone")

        var unnamedRecord = named.txtRecord
        unnamedRecord.removeValue(forKey: "name")
        #expect(try BonjourMetadataParser.parse(unnamedRecord).displayName == nil)
    }
}

@Suite("Injected Bonjour discovery")
struct BonjourDiscoveryTests {
    @Test("Discovery additions, metadata changes, and removals are distinct")
    func discoveryLifecycle() async {
        let local = node(1)
        let peer = node(2)
        let endpoint = BonjourEndpointID(rawValue: uuid(9))
        let browser = ScriptedBonjourBrowser()
        let firstConnection = ScriptedBonjourConnection()
        let secondConnection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(firstConnection), .success(secondConnection)])
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: local,
            browser: browser,
            connectionFactory: factory,
            diagnosticSink: diagnostics.record
        )
        await coordinator.start()

        browser.send(.added(advertisement(endpoint: endpoint, peer: peer, nonceByte: 1)))
        await settle()
        browser.send(.changed(advertisement(endpoint: endpoint, peer: peer, nonceByte: 2)))
        await settle()
        browser.send(.removed(endpointID: endpoint))
        await settle()

        #expect(factory.requestedEndpoints == [endpoint, endpoint])
        #expect(firstConnection.cancelCount == 1)
        #expect(await coordinator.discoveredCandidates().isEmpty)
        #expect(diagnostics.events.contains { if case .discoveryAdded = $0 { true } else { false } })
        #expect(diagnostics.events.contains { if case .discoveryChanged = $0 { true } else { false } })
        #expect(diagnostics.events.contains(.discoveryRemoved(endpoint)))
        #expect(secondConnection.cancelCount == 0, "Discovery loss must not tear down a live connection")
    }

    @Test("Node-ID hints are untrusted and a local collision never starts a connection")
    func dishonestAndCollidingHints() async {
        let local = node(1)
        let endpoint = BonjourEndpointID(rawValue: uuid(8))
        let browser = ScriptedBonjourBrowser()
        let connection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(connection)])
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: local,
            browser: browser,
            connectionFactory: factory,
            diagnosticSink: diagnostics.record
        )
        await coordinator.start()

        browser.send(.added(advertisement(endpoint: endpoint, peer: local, nonceByte: 1)))
        await settle()
        #expect(factory.requestedEndpoints.isEmpty)
        #expect(diagnostics.events.contains { if case .nodeIDHintCollision = $0 { true } else { false } })

        let dishonestHint = node(3)
        browser.send(.changed(advertisement(endpoint: endpoint, peer: dishonestHint, nonceByte: 2)))
        await settle()
        #expect(factory.requestedEndpoints == [endpoint])
        #expect(await coordinator.discoveredCandidates().first?.nodeIDHint == dishonestHint)
        #expect(!diagnostics.events.contains { event in
            // Discovery deliberately has no authenticated/succeeded diagnostic.
            if case .connectionState(_, .ready) = event { return true }
            return false
        })
    }

    @Test("Simultaneous discovery selects exactly the lower canonical Node ID as initiator")
    func simultaneousDiscovery() async {
        let lower = node(1)
        let higher = node(2)
        let lowerBrowser = ScriptedBonjourBrowser()
        let higherBrowser = ScriptedBonjourBrowser()
        let lowerFactory = ScriptedBonjourConnectionFactory(results: [.success(ScriptedBonjourConnection())])
        let higherFactory = ScriptedBonjourConnectionFactory(results: [.success(ScriptedBonjourConnection())])
        let lowerCoordinator = BonjourDiscoveryCoordinator(
            localNodeID: lower,
            browser: lowerBrowser,
            connectionFactory: lowerFactory
        )
        let higherCoordinator = BonjourDiscoveryCoordinator(
            localNodeID: higher,
            browser: higherBrowser,
            connectionFactory: higherFactory
        )
        await lowerCoordinator.start()
        await higherCoordinator.start()

        lowerBrowser.send(.added(advertisement(endpoint: BonjourEndpointID(), peer: higher, nonceByte: 1)))
        higherBrowser.send(.added(advertisement(endpoint: BonjourEndpointID(), peer: lower, nonceByte: 2)))
        await settle()

        #expect(lowerFactory.requestedEndpoints.count == 1)
        #expect(higherFactory.requestedEndpoints.isEmpty)
    }

    @Test("Callbacks from an earlier browser generation are ignored")
    func staleCallbacks() async {
        let browser = ScriptedBonjourBrowser()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(ScriptedBonjourConnection())])
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1),
            browser: browser,
            connectionFactory: factory,
            diagnosticSink: diagnostics.record
        )
        await coordinator.start()
        await coordinator.start()

        browser.send(
            .added(advertisement(endpoint: BonjourEndpointID(), peer: node(2), nonceByte: 1)),
            toStart: 0
        )
        await settle()

        #expect(factory.requestedEndpoints.isEmpty)
        #expect(diagnostics.events.contains(.staleCallbackIgnored(component: "browser", generation: 1)))
    }

    @Test("A failed connection retries while the peer remains discovered")
    func reconnectsWithoutDiscoveryChange() async throws {
        let endpoint = BonjourEndpointID(rawValue: uuid(7))
        let browser = ScriptedBonjourBrowser()
        let firstConnection = ScriptedBonjourConnection()
        let secondConnection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [
            .success(firstConnection),
            .success(secondConnection)
        ])
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1),
            browser: browser,
            connectionFactory: factory,
            reconnectDelay: .milliseconds(1)
        )
        await coordinator.start()

        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 1)))
        await settle()
        firstConnection.send(.failed(reason: "peer unavailable"))
        try await Task.sleep(for: .milliseconds(20))
        await settle()

        #expect(factory.requestedEndpoints == [endpoint, endpoint])
    }

    @Test("Permission denial and browser failure have structured diagnostics")
    func browserFailures() async {
        let browser = ScriptedBonjourBrowser()
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1),
            browser: browser,
            connectionFactory: ScriptedBonjourConnectionFactory(),
            diagnosticSink: diagnostics.record
        )
        await coordinator.start()
        browser.send(.permissionDenied)
        browser.send(.state(.failed(reason: "dns unavailable")))
        await settle()

        #expect(diagnostics.events.contains(.permissionDenied(component: "browser")))
        #expect(diagnostics.events.contains(.browserState(.failed(reason: "dns unavailable"))))
    }

    @Test("Listener failure, permission denial, and stale callbacks are structured")
    func listenerFailures() async {
        let listener = ScriptedBonjourListener()
        let diagnostics = DiagnosticRecorder()
        let accepted = ConnectionRecorder()
        let coordinator = BonjourListenerCoordinator(
            listener: listener,
            diagnosticSink: diagnostics.record,
            connectionHandler: accepted.record
        )
        await coordinator.start()
        listener.send(.state(.failed(reason: "bind failed")))
        listener.send(.permissionDenied)
        listener.send(.connection(ScriptedBonjourConnection()))
        await settle()
        await coordinator.start()
        listener.send(.state(.ready(port: 1234)), toStart: 0)
        await settle()

        #expect(accepted.count == 1)
        #expect(diagnostics.events.contains(.listenerState(.failed(reason: "bind failed"))))
        #expect(diagnostics.events.contains(.permissionDenied(component: "listener")))
        #expect(diagnostics.events.contains(.staleCallbackIgnored(component: "listener", generation: 1)))
    }

    @Test("Stopping discovery cancels active connection attempts and ignores their callbacks")
    func connectionCancellation() async {
        let browser = ScriptedBonjourBrowser()
        let connection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(connection)])
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1),
            browser: browser,
            connectionFactory: factory,
            diagnosticSink: diagnostics.record
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: BonjourEndpointID(), peer: node(2), nonceByte: 1)))
        await settle()
        await coordinator.stop()
        connection.send(.ready)
        await settle()

        #expect(browser.cancelCount == 1)
        #expect(connection.cancelCount == 1)
        #expect(diagnostics.events.contains { if case .staleCallbackIgnored(component: "connection", generation: 1) = $0 { true } else { false } })
    }

    private func advertisement(
        endpoint: BonjourEndpointID,
        peer: NodeID,
        nonceByte: UInt8
    ) -> BonjourAdvertisement {
        BonjourAdvertisement(
            endpointID: endpoint,
            interfaceNames: ["en0"],
            txtRecord: BonjourDiscoveryMetadata(
                nodeIDHint: peer,
                advertisementNonce: Data(repeating: nonceByte, count: 32)
            ).txtRecord
        )
    }

    private func node(_ byte: UInt8) -> NodeID {
        NodeID(rawValue: uuid(byte))
    }

    private func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BonjourDiagnostic] = []

    var events: [BonjourDiagnostic] {
        lock.withLock { storage }
    }

    func record(_ event: BonjourDiagnostic) {
        lock.withLock { storage.append(event) }
    }
}

private final class ConnectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [any BonjourConnection] = []

    var count: Int { lock.withLock { storage.count } }

    func record(_ connection: any BonjourConnection) {
        lock.withLock { storage.append(connection) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
