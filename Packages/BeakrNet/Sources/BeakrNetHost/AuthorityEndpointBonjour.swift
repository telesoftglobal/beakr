import Foundation
import BeakrNetAuthority
import BeakrNetCore

public enum AuthorityEndpointBonjourError: Error, Equatable, Sendable {
    case invalidTXTRecord
    case recordTooLarge
    case listenerPortMismatch
}

/// Experimental, versioned TXT framing. Parsing grants no trust.
public enum AuthorityEndpointBonjourCodec {
    public static let serviceType = "_beakr-auth._tcp"
    public static let maximumTXTBytes = 1_300
    private static let chunkBytes = 200
    private static let maximumChunks = 7

    public static func encode(_ record: SignedAuthorityEndpoint) throws -> [String: String] {
        let bytes = Array(try record.encoded().base64EncodedString().utf8)
        let count = (bytes.count + chunkBytes - 1) / chunkBytes
        guard count > 0, count <= maximumChunks else { throw AuthorityEndpointBonjourError.recordTooLarge }
        var fields = ["v": "1", "n": String(count)]
        for index in 0..<count {
            let start = index * chunkBytes
            fields["d\(index)"] = String(
                decoding: bytes[start..<min(start + chunkBytes, bytes.count)], as: UTF8.self
            )
        }
        guard wireSize(fields) <= maximumTXTBytes else { throw AuthorityEndpointBonjourError.recordTooLarge }
        return fields
    }

    public static func decode(_ fields: [String: String]) throws -> SignedAuthorityEndpoint {
        guard fields.count <= maximumChunks + 2, fields["v"] == "1",
              let countText = fields["n"], countText.utf8.count == 1,
              let count = Int(countText), count > 0, count <= maximumChunks,
              fields.count == count + 2,
              fields.allSatisfy({ $0.key.utf8.count + $0.value.utf8.count + 1 <= 255 }),
              wireSize(fields) <= maximumTXTBytes else {
            throw AuthorityEndpointBonjourError.invalidTXTRecord
        }
        var encoded = ""
        for index in 0..<count {
            guard let chunk = fields["d\(index)"], !chunk.isEmpty,
                  chunk.utf8.count <= chunkBytes,
                  index == count - 1 || chunk.utf8.count == chunkBytes else {
                throw AuthorityEndpointBonjourError.invalidTXTRecord
            }
            encoded += chunk
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw AuthorityEndpointBonjourError.invalidTXTRecord
        }
        return try SignedAuthorityEndpoint.decode(data)
    }

    private static func wireSize(_ fields: [String: String]) -> Int {
        fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 }
    }
}

#if canImport(Network)
import Network

public enum AuthorityEndpointBonjourAdvertisement {
    /// The caller must own the listener and renew the signed record before expiry.
    /// This does not start a listener or change its TLS identity.
    public static func publish(_ record: SignedAuthorityEndpoint, on listener: NWListener) throws {
        guard let port = listener.port else { throw AuthorityEndpointBonjourError.listenerPortMismatch }
        listener.service = try service(record, boundPort: port.rawValue)
    }

    public static func service(
        _ record: SignedAuthorityEndpoint, boundPort: UInt16
    ) throws -> NWListener.Service {
        guard boundPort != 0, record.claims.port == boundPort else {
            throw AuthorityEndpointBonjourError.listenerPortMismatch
        }
        let fields = try AuthorityEndpointBonjourCodec.encode(record)
        return NWListener.Service(
            name: record.claims.networkID.rawValue.uuidString.lowercased(),
            type: AuthorityEndpointBonjourCodec.serviceType,
            txtRecord: NWTXTRecord(fields)
        )
    }
}

public enum AuthorityEndpointBrowserEvent: Sendable {
    /// All records are still untrusted; process through the persistent cache.
    case candidates([SignedAuthorityEndpoint], truncated: Bool)
    case ready
    case unavailable
    case stopped
}

/// One-shot bounded browser. Its mutable lifecycle is confined to its serial
/// queue; no per-advertisement tasks, retained endpoint registry or retry loop.
public final class AuthorityEndpointBonjourBrowser: @unchecked Sendable {
    public let events: AsyncStream<AuthorityEndpointBrowserEvent>
    private let continuation: AsyncStream<AuthorityEndpointBrowserEvent>.Continuation
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "BeakrNet.authority-browser")
    private let networkID: NetworkID
    private let maximumCandidates: Int
    private var started = false
    private var cancelled = false

    public init(networkID: NetworkID, maximumCandidates: Int = 32) {
        precondition(maximumCandidates > 0 && maximumCandidates <= 128)
        self.networkID = networkID
        self.maximumCandidates = maximumCandidates
        let stream = AsyncStream<AuthorityEndpointBrowserEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        continuation = stream.continuation
        browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: AuthorityEndpointBonjourCodec.serviceType, domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, !self.cancelled else { return }
            switch state {
            case .ready: self.continuation.yield(.ready)
            case .waiting, .failed: self.continuation.yield(.unavailable)
            case .cancelled:
                self.cancelled = true
                self.continuation.yield(.stopped)
                self.continuation.finish()
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.cancelled else { return }
            var candidates: [SignedAuthorityEndpoint] = []
            // Bound parsing work as well as the number of delivered candidates.
            for result in results.prefix(self.maximumCandidates) {
                guard case .bonjour(let txt) = result.metadata,
                      let record = try? AuthorityEndpointBonjourCodec.decode(txt.dictionary),
                      record.claims.networkID == self.networkID else { continue }
                candidates.append(record)
            }
            self.continuation.yield(.candidates(
                candidates, truncated: results.count > self.maximumCandidates
            ))
        }
        continuation.onTermination = { [weak self] _ in self?.cancel() }
    }

    public func start() {
        queue.async { [self] in
            guard !started, !cancelled else { return }
            started = true
            browser.start(queue: queue)
        }
    }

    public func cancel() {
        queue.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            browser.cancel()
            continuation.yield(.stopped)
            continuation.finish()
        }
    }

    deinit {
        browser.cancel()
        continuation.finish()
    }
}
#endif
