#if canImport(Network)
import Foundation
import BeakrNetAuthority
import BeakrNetCore

public enum AuthorityEndpointDiscoveryError: Error, Equatable, Sendable {
    case stopped
    case unavailable
}

/// Owns one browser and one serial verification consumer for an immutable trust
/// binding. Replacing a profile or authority requires stopping this owner first.
public actor AuthorityEndpointDiscovery {
    private let cache: PersistentAuthorityEndpointCache
    private let events: AsyncStream<AuthorityEndpointBrowserEvent>
    private let startBrowser: @Sendable () -> Void
    private let cancelBrowser: @Sendable () -> Void
    private var consumer: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var persistenceFailure: (any Error)?

    public init(cache: PersistentAuthorityEndpointCache, networkID: NetworkID) {
        let browser = AuthorityEndpointBonjourBrowser(networkID: networkID)
        self.cache = cache
        events = browser.events
        startBrowser = { browser.start() }
        cancelBrowser = { browser.cancel() }
    }

    // Injectable event source keeps lifecycle tests off the LAN.
    init(cache: PersistentAuthorityEndpointCache,
         events: AsyncStream<AuthorityEndpointBrowserEvent>,
         start: @escaping @Sendable () -> Void,
         cancel: @escaping @Sendable () -> Void) {
        self.cache = cache
        self.events = events
        startBrowser = start
        cancelBrowser = cancel
    }

    public func start() throws {
        guard !stopped else { throw AuthorityEndpointDiscoveryError.stopped }
        guard !started else { return }
        started = true
        let events = self.events
        consumer = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.consume(event)
            }
            await self?.sourceEnded()
        }
        startBrowser()
    }

    /// A stopped owner cannot return even a still-fresh persisted route.
    public func resolve(timeout: Duration = .seconds(5)) async throws -> VerifiedAuthorityEndpoint {
        try start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: min(max(timeout, .zero), .seconds(30)))
        while true {
            try Task.checkCancellation()
            guard !stopped else { throw AuthorityEndpointDiscoveryError.stopped }
            if let persistenceFailure { throw persistenceFailure }
            let endpoint = try await cache.current()
            try Task.checkCancellation()
            guard !stopped else { throw AuthorityEndpointDiscoveryError.stopped }
            if let persistenceFailure { throw persistenceFailure }
            if let endpoint { return endpoint }
            guard clock.now < deadline else { throw AuthorityEndpointDiscoveryError.unavailable }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(50))))
        }
    }

    public func stop() async {
        stopped = true
        cancelBrowser()
        let task = consumer
        task?.cancel()
        await task?.value
        consumer = nil
    }

    private func sourceEnded() {
        stopped = true
        cancelBrowser()
    }

    private func consume(_ event: AuthorityEndpointBrowserEvent) async {
        guard !stopped else { return }
        switch event {
        case .candidates(let records, _):
            for record in records.prefix(128) {
                guard !stopped, !Task.isCancelled else { return }
                do {
                    try await cache.accept(record)
                } catch is AuthorityEndpointError {
                    // Untrusted or stale advertisements cannot replace a route.
                } catch is AuthorityEndpointPersistenceError {
                    // Conflicting/older publications likewise retain the high-water mark.
                } catch {
                    persistenceFailure = error
                    return
                }
            }
        case .stopped:
            stopped = true
        case .ready, .unavailable:
            break // Cached routes still require signature and freshness validation.
        }
    }

    deinit {
        consumer?.cancel()
        cancelBrowser()
    }
}
#endif
