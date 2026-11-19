import Foundation
import Testing
@testable import BeakrNetCore
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
    @Test("Network filtering rejects foreign and legacy advertisements before connecting")
    func networkFiltering() async throws {
        let network = NetworkID()
        let otherNetwork = NetworkID()
        let endpoint = BonjourEndpointID()
        let browser = ScriptedBonjourBrowser()
        let connection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(connection)])
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), networkID: network, browser: browser,
            connectionFactory: factory, diagnosticSink: diagnostics.record
        )
        func record(_ id: NetworkID?) -> BonjourAdvertisement {
            BonjourAdvertisement(endpointID: endpoint, txtRecord: BonjourDiscoveryMetadata(
                networkID: id, nodeIDHint: node(2), advertisementNonce: Data(repeating: 1, count: 32)
            ).txtRecord)
        }
        #expect(try BonjourMetadataParser.parse(record(network).txtRecord).networkID == network)
        var malformed = record(network).txtRecord
        malformed["network"] = "not-a-uuid"
        #expect(throws: BonjourMetadataError.invalidNetworkID) {
            try BonjourMetadataParser.parse(malformed)
        }
        await coordinator.start()
        browser.send(.added(record(otherNetwork)))
        await waitUntil { diagnostics.events.count >= 1 }
        browser.send(.changed(record(nil)))
        await waitUntil { diagnostics.events.count >= 2 }
        #expect(factory.requestedEndpoints.isEmpty)
        #expect(await coordinator.discoveredCandidates().isEmpty)
        browser.send(.changed(record(network)))
        await waitUntil { factory.requestedEndpoints.count == 1 }
        #expect(factory.requestedEndpoints == [endpoint])
        browser.send(.changed(record(otherNetwork)))
        await waitUntil { connection.cancelCount == 1 }
        #expect(connection.cancelCount == 1)
        #expect(await coordinator.discoveredCandidates().isEmpty)
        let resources = await coordinator.resourceSnapshot()
        #expect(resources.connections == 0)
        #expect(resources.reconnectTasks == 0)
        #expect(resources.connectionAttemptTasks == 0)
        await coordinator.stop()
    }

    @Test("Resource snapshots distinguish owned timers and clear after stop")
    func resourceSnapshotLifecycle() async {
        let browser = ScriptedBonjourBrowser()
        let connection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(connection)])
        let accepted = ConnectionRecorder()
        let endpoint = BonjourEndpointID()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            reconnectDelay: .seconds(30), discoveryLossGracePeriod: .seconds(30),
            connectionAttemptTimeout: .seconds(30),
            connectionHandler: { _, connection in accepted.record(connection) }
        )
        let empty = await coordinator.resourceSnapshot()
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 1)))
        await waitUntil { await coordinator.resourceSnapshot().connectionAttemptTasks == 1 }
        let attempting = await coordinator.resourceSnapshot()
        #expect(attempting.connections == 1)
        #expect(attempting.connectionAttemptTasks == 1)
        #expect(attempting.reconnectTasks == 0)
        connection.send(.ready)
        await waitUntil { accepted.count == 1 }
        #expect(await coordinator.resourceSnapshot().connectionAttemptTasks == 0)
        browser.send(.removed(endpointID: endpoint))
        await waitUntil { await coordinator.resourceSnapshot().discoveryLossTasks == 1 }
        #expect(await coordinator.resourceSnapshot().discoveryLossTasks == 1)
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 1)))
        await waitUntil { await coordinator.resourceSnapshot().discoveryLossTasks == 0 }
        connection.send(.failed(reason: "resource snapshot test"))
        await waitUntil { await coordinator.resourceSnapshot().reconnectTasks == 1 }
        let retrying = await coordinator.resourceSnapshot()
        #expect(retrying.connections == 0)
        #expect(retrying.reconnectTasks == 1)
        #expect(retrying.discoveryLossTasks == 0)
        #expect(retrying.connectionAttemptTasks == 0)
        await coordinator.stop()
        #expect(await coordinator.resourceSnapshot() == empty)
    }

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
            discoveryLossGracePeriod: .milliseconds(10),
            diagnosticSink: diagnostics.record
        )
        await coordinator.start()

        browser.send(.added(advertisement(endpoint: endpoint, peer: peer, nonceByte: 1)))
        await settle()
        browser.send(.changed(advertisement(endpoint: endpoint, peer: peer, nonceByte: 2)))
        await settle()
        browser.send(.removed(endpointID: endpoint))
        await settle()
        try? await Task.sleep(for: .milliseconds(20))
        await settle()

        #expect(factory.requestedEndpoints == [endpoint, endpoint])
        #expect(firstConnection.cancelCount == 1)
        #expect(await coordinator.discoveredCandidates().isEmpty)
        #expect(diagnostics.events.contains { if case .discoveryAdded = $0 { true } else { false } })
        #expect(diagnostics.events.contains { if case .discoveryChanged = $0 { true } else { false } })
        #expect(diagnostics.events.contains(.discoveryRemoved(endpoint)))
        #expect(secondConnection.cancelCount == 1, "Discovery loss must expire a stale live connection")
    }

    @Test("Discovery returning during the grace period keeps the handed-off connection")
    func transientDiscoveryLossKeepsConnection() async {
        let local = node(1)
        let peer = node(2)
        let endpoint = BonjourEndpointID(rawValue: uuid(10))
        let browser = ScriptedBonjourBrowser()
        let connection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(connection)])
        let accepted = ConnectionRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: local,
            browser: browser,
            connectionFactory: factory,
            discoveryLossGracePeriod: .milliseconds(100),
            connectionHandler: { _, connection in accepted.record(connection) }
        )
        await coordinator.start()

        let advertisement = advertisement(endpoint: endpoint, peer: peer, nonceByte: 1)
        browser.send(.added(advertisement))
        await waitUntil { factory.requestedEndpoints.count == 1 }
        _ = await coordinator.discoveredCandidates()
        connection.send(.ready)
        await waitUntil { accepted.count == 1 }
        browser.send(.removed(endpointID: endpoint))
        await waitUntil { await coordinator.discoveredCandidates().isEmpty }
        browser.send(.added(advertisement))
        await waitUntil { await coordinator.discoveredCandidates().count == 1 }
        try? await Task.sleep(for: .milliseconds(150))

        #expect(connection.cancelCount == 0)
        #expect(factory.requestedEndpoints == [endpoint])
        await coordinator.stop()
    }

    @Test("A handed-off connection expires when discovery does not return")
    func discoveryLossExpiresHandedOffConnection() async {
        let browser = ScriptedBonjourBrowser()
        let connection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(connection)])
        let accepted = ConnectionRecorder()
        let ended = ConnectionIDRecorder()
        let endpoint = BonjourEndpointID()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            discoveryLossGracePeriod: .milliseconds(20),
            connectionHandler: { _, connection in accepted.record(connection) },
            connectionEndedHandler: ended.record
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 1)))
        await waitUntil { factory.requestedEndpoints.count == 1 }
        _ = await coordinator.discoveredCandidates()
        connection.send(.ready)
        await waitUntil { accepted.count == 1 }
        browser.send(.removed(endpointID: endpoint))
        await waitUntil { ended.ids == [connection.id] }
        #expect(connection.cancelCount == 1)
        await coordinator.stop()
        #expect(ended.ids == [connection.id])
    }

    @Test("Removed pending attempts cannot hand off after rediscovery", arguments: [UInt8(1), UInt8(2)])
    func removedPendingAttempt(nonce: UInt8) async {
        let browser = ScriptedBonjourBrowser()
        let old = ScriptedBonjourConnection()
        let replacement = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(old), .success(replacement)])
        let accepted = ConnectionRecorder()
        let ended = ConnectionIDRecorder()
        let diagnostics = DiagnosticRecorder()
        let endpoint = BonjourEndpointID()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            diagnosticSink: diagnostics.record,
            connectionHandler: { _, connection in accepted.record(connection) },
            connectionEndedHandler: ended.record
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 1)))
        await waitUntil { factory.requestedEndpoints.count == 1 }
        _ = await coordinator.discoveredCandidates()
        browser.send(.removed(endpointID: endpoint))
        await waitUntil { old.cancelCount == 1 }
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: nonce)))
        await waitUntil { factory.requestedEndpoints.count == 2 }
        _ = await coordinator.discoveredCandidates()
        old.send(.ready)
        old.send(.cancelled)
        replacement.send(.ready)
        await waitUntil { accepted.count == 1 }
        await waitUntil {
            diagnostics.events.filter {
                if case .staleCallbackIgnored(component: "connection", generation: 1) = $0 { return true }
                return false
            }.count == 3
        }
        #expect(old.cancelCount == 1)
        #expect(replacement.cancelCount == 0)
        #expect(ended.ids.isEmpty)
        await coordinator.stop()
        #expect(ended.ids == [replacement.id])
    }

    @Test("A new nonce retires a handed-off connection exactly once", arguments: [false, true])
    func replacesHandedOffConnection(removeFirst: Bool) async {
        let browser = ScriptedBonjourBrowser()
        let old = ScriptedBonjourConnection()
        let replacement = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(old), .success(replacement)])
        let accepted = ConnectionRecorder()
        let ended = ConnectionIDRecorder()
        let endpoint = BonjourEndpointID()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            discoveryLossGracePeriod: .milliseconds(100),
            connectionHandler: { _, connection in accepted.record(connection) },
            connectionEndedHandler: ended.record
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 1)))
        await waitUntil { factory.requestedEndpoints.count == 1 }
        _ = await coordinator.discoveredCandidates()
        old.send(.ready)
        await waitUntil { accepted.count == 1 }
        if removeFirst {
            browser.send(.removed(endpointID: endpoint))
            await waitUntil { await coordinator.discoveredCandidates().isEmpty }
            #expect(old.cancelCount == 0)
        }
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 2)))
        await waitUntil { factory.requestedEndpoints.count == 2 }
        _ = await coordinator.discoveredCandidates()
        replacement.send(.ready)
        old.send(.cancelled)
        await waitUntil { accepted.count == 2 }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(old.cancelCount == 1)
        #expect(ended.ids == [old.id])
        #expect(replacement.cancelCount == 0)
        await coordinator.stop()
        #expect(ended.ids == [old.id, replacement.id])
    }

    #if canImport(Network)
    @Test("Incoming connections hand off and end once without replacing their callback")
    func incomingConnectionLifecycle() {
        let connection = ScriptedBonjourConnection()
        let accepted = ConnectionRecorder()
        let ended = ConnectionIDRecorder()
        let handler = BonjourIncomingConnectionHandler(connection: connection) { event in
            switch event {
            case .connection(let connection): accepted.record(connection)
            case .connectionEnded(let id): ended.record(id)
            default: break
            }
        }
        handler.start()
        connection.send(.ready)
        connection.send(.ready)
        connection.send(.failed(reason: "test"))
        connection.send(.cancelled)
        connection.send(.ready)
        #expect(accepted.count == 1)
        #expect(ended.ids == [connection.id])
        #expect(connection.cancelCount == 1)
    }

    @Test("Incoming failure before readiness releases the connection without a handoff")
    func incomingFailureBeforeReady() throws {
        var connection: ScriptedBonjourConnection? = ScriptedBonjourConnection()
        weak var weakConnection: ScriptedBonjourConnection?
        weakConnection = connection
        let accepted = ConnectionRecorder()
        let ended = ConnectionIDRecorder()
        let handler = BonjourIncomingConnectionHandler(connection: try #require(connection)) { event in
            switch event {
            case .connection(let connection): accepted.record(connection)
            case .connectionEnded(let id): ended.record(id)
            default: break
            }
        }
        handler.start()
        connection?.send(.failed(reason: "test"))
        connection?.send(.cancelled)
        #expect(connection?.cancelCount == 1)
        connection = nil
        #expect(weakConnection == nil)
        #expect(accepted.count == 0)
        #expect(ended.ids.isEmpty)
    }
    #endif

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
        await waitUntil {
            diagnostics.events.contains { if case .nodeIDHintCollision = $0 { true } else { false } }
        }
        #expect(factory.requestedEndpoints.isEmpty)
        #expect(diagnostics.events.contains { if case .nodeIDHintCollision = $0 { true } else { false } })

        let dishonestHint = node(3)
        browser.send(.changed(advertisement(endpoint: endpoint, peer: dishonestHint, nonceByte: 2)))
        await waitUntil { factory.requestedEndpoints == [endpoint] }
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
        await waitUntil { lowerFactory.requestedEndpoints.count == 1 }
        await waitUntil { await higherCoordinator.discoveredCandidates().count == 1 }

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

    @Test("Authenticated connections that immediately close retain exponential backoff")
    func shortLivedAuthenticatedConnectionsBackOff() async {
        let browser = ScriptedBonjourBrowser()
        let attempts = (0..<5).map { _ in ScriptedBonjourConnection() }
        let factory = ScriptedBonjourConnectionFactory(results: attempts.map { .success($0) })
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            reconnectDelay: .milliseconds(2), maximumReconnectDelay: .milliseconds(8),
            diagnosticSink: diagnostics.record,
            authenticateConnection: { _, _ in true }
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: BonjourEndpointID(), peer: node(2), nonceByte: 1)))
        for index in 0..<4 {
            await waitUntil { factory.requestedEndpoints.count == index + 1 }
            _ = await coordinator.discoveredCandidates()
            attempts[index].send(.ready)
            // Let authentication complete, then reproduce a peer closing immediately.
            try? await Task.sleep(for: .milliseconds(20))
            attempts[index].send(.cancelled)
            await waitUntil { factory.requestedEndpoints.count == index + 2 }
        }
        let delays = diagnostics.events.compactMap { event -> Duration? in
            if case .reconnectScheduled(_, let delay) = event { return delay }
            return nil
        }
        #expect(delays == [.milliseconds(2), .milliseconds(4), .milliseconds(8), .milliseconds(8)])
        await coordinator.stop()
    }

    @Test("Transport-ready failures back off to the cap; sustained admission resets retries")
    func authenticationBackoff() async {
        let browser = ScriptedBonjourBrowser()
        let attempts = (0..<6).map { _ in ScriptedBonjourConnection() }
        let factory = ScriptedBonjourConnectionFactory(results: attempts.map { .success($0) })
        let diagnostics = DiagnosticRecorder()
        let admitted = attempts[4].id
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            reconnectDelay: .milliseconds(2), maximumReconnectDelay: .milliseconds(8),
            stableConnectionDuration: .milliseconds(10),
            diagnosticSink: diagnostics.record,
            authenticateConnection: { _, connection in connection.id == admitted }
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: BonjourEndpointID(), peer: node(2), nonceByte: 1)))
        for index in 0..<5 {
            await waitUntil { factory.requestedEndpoints.count == index + 1 }
            _ = await coordinator.discoveredCandidates()
            attempts[index].send(.ready)
            if index < 4 {
                await waitUntil { factory.requestedEndpoints.count == index + 2 }
            }
        }
        // Wait for the async authentication completion to be processed.
        try? await Task.sleep(for: .milliseconds(20))
        attempts[4].send(.failed(reason: "authenticated route ended"))
        await waitUntil { factory.requestedEndpoints.count == 6 }
        let delays = diagnostics.events.compactMap { event -> Duration? in
            if case .reconnectScheduled(_, let delay) = event { return delay }
            return nil
        }
        #expect(delays == [.milliseconds(2), .milliseconds(4), .milliseconds(8), .milliseconds(8), .milliseconds(2)])
        await coordinator.stop()
    }

    @Test("Stalled transport establishment retries without discovery changes", arguments: [
        BonjourConnectionState.preparing, .waiting(reason: "path unavailable")
    ])
    func stalledConnectionRetries(state: BonjourConnectionState) async {
        let browser = ScriptedBonjourBrowser()
        let old = ScriptedBonjourConnection()
        let replacement = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(old), .success(replacement)])
        let accepted = ConnectionRecorder()
        let diagnostics = DiagnosticRecorder()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            reconnectDelay: .milliseconds(5), connectionAttemptTimeout: .milliseconds(100),
            diagnosticSink: diagnostics.record,
            connectionHandler: { _, connection in accepted.record(connection) }
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: BonjourEndpointID(), peer: node(2), nonceByte: 1)))
        await waitUntil { factory.requestedEndpoints.count == 1 }
        _ = await coordinator.discoveredCandidates()
        old.send(state)
        await waitUntil { factory.requestedEndpoints.count == 2 }
        _ = await coordinator.discoveredCandidates()
        #expect(old.cancelCount == 1)
        #expect(diagnostics.events.contains(.connectionState(old.id, .failed(reason: "connection-attempt-timeout"))))
        // Late callbacks from the timed-out connection must not affect its replacement.
        old.send(.ready)
        old.send(.cancelled)
        replacement.send(.ready)
        await waitUntil { accepted.count == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(accepted.count == 1)
        #expect(replacement.cancelCount == 0)
        #expect(factory.requestedEndpoints.count == 2)
        await coordinator.stop()
    }

    @Test("Removing or stopping a pending attempt cancels its timeout", arguments: [false, true])
    func pendingTimeoutCleanup(stop: Bool) async {
        let browser = ScriptedBonjourBrowser()
        let connection = ScriptedBonjourConnection()
        let factory = ScriptedBonjourConnectionFactory(results: [.success(connection)])
        let diagnostics = DiagnosticRecorder()
        let endpoint = BonjourEndpointID()
        let coordinator = BonjourDiscoveryCoordinator(
            localNodeID: node(1), browser: browser, connectionFactory: factory,
            reconnectDelay: .milliseconds(5), connectionAttemptTimeout: .milliseconds(100),
            diagnosticSink: diagnostics.record
        )
        await coordinator.start()
        browser.send(.added(advertisement(endpoint: endpoint, peer: node(2), nonceByte: 1)))
        await waitUntil { factory.requestedEndpoints.count == 1 }
        _ = await coordinator.discoveredCandidates()
        if stop {
            await coordinator.stop()
        } else {
            browser.send(.removed(endpointID: endpoint))
            await waitUntil { connection.cancelCount == 1 }
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(connection.cancelCount == 1)
        #expect(factory.requestedEndpoints.count == 1)
        #expect(!diagnostics.events.contains { if case .reconnectScheduled = $0 { true } else { false } })
        await coordinator.stop()
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
        await waitUntil { factory.requestedEndpoints.count == 1 }
        // An actor hop waits for upsert/startConnection to finish installing the handler.
        _ = await coordinator.discoveredCandidates()
        firstConnection.send(.failed(reason: "peer unavailable"))
        await waitUntil { factory.requestedEndpoints.count == 2 }

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
        let ended = ConnectionIDRecorder()
        let coordinator = BonjourListenerCoordinator(
            listener: listener,
            diagnosticSink: diagnostics.record,
            connectionHandler: accepted.record,
            connectionEndedHandler: ended.record
        )
        await coordinator.start()
        listener.send(.state(.failed(reason: "bind failed")))
        listener.send(.permissionDenied)
        let connection = ScriptedBonjourConnection()
        listener.send(.connection(connection))
        listener.send(.connectionEnded(connection.id))
        await settle()
        await coordinator.start()
        listener.send(.state(.ready(port: 1234)), toStart: 0)
        await settle()

        #expect(accepted.count == 1)
        #expect(ended.ids == [connection.id])
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

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await condition(), "Expected asynchronous discovery event before deadline")
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

private final class ConnectionIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIDs: [UUID] = []
    var ids: [UUID] { lock.withLock { recordedIDs } }

    func record(_ id: UUID) {
        lock.withLock { recordedIDs.append(id) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
