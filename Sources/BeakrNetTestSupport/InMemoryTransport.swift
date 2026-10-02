import BeakrNetCore

public enum InMemoryTransportError: Error, Equatable, Sendable {
    case notConnected
    case closed
    case peerClosed
}

public actor InMemoryTransport: BeakrNetTransport {
    public nonisolated let id: TransportID
    public nonisolated let kind = TransportKind.inMemory
    public nonisolated let capabilities = TransportCapabilities.inMemory

    private var peer: InMemoryTransport?
    private var queuedEnvelopes: [BeakrNetEnvelope] = []
    private var waitingReceivers: [CheckedContinuation<BeakrNetEnvelope?, Never>] = []
    private var isClosed = false

    public init(id: TransportID = TransportID()) {
        self.id = id
    }

    public static func makePair() async -> (InMemoryTransport, InMemoryTransport) {
        let first = InMemoryTransport()
        let second = InMemoryTransport()
        await first.connect(to: second)
        await second.connect(to: first)
        return (first, second)
    }

    public func send(_ envelope: BeakrNetEnvelope) async throws {
        guard !isClosed else { throw InMemoryTransportError.closed }
        guard let peer else { throw InMemoryTransportError.notConnected }
        try await peer.enqueue(envelope)
    }

    public func receive() async -> BeakrNetEnvelope? {
        if !queuedEnvelopes.isEmpty {
            return queuedEnvelopes.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waitingReceivers.append(continuation)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let receivers = waitingReceivers
        waitingReceivers.removeAll()
        receivers.forEach { $0.resume(returning: nil) }
        await peer?.peerDidClose()
        peer = nil
    }

    private func connect(to peer: InMemoryTransport) {
        self.peer = peer
    }

    private func enqueue(_ envelope: BeakrNetEnvelope) throws {
        guard !isClosed else { throw InMemoryTransportError.peerClosed }
        if waitingReceivers.isEmpty {
            queuedEnvelopes.append(envelope)
        } else {
            waitingReceivers.removeFirst().resume(returning: envelope)
        }
    }

    private func peerDidClose() {
        peer = nil
    }
}
