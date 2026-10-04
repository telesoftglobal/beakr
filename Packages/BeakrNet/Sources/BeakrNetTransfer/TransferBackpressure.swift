import Foundation

public struct TransferBackpressurePolicy: Equatable, Sendable {
    public let maximumInFlightChunks: Int
    public let maximumRetryDelay: TimeInterval

    public init(maximumInFlightChunks: Int = 4, maximumRetryDelay: TimeInterval = 300) {
        precondition(maximumInFlightChunks > 0 && maximumRetryDelay > 0)
        self.maximumInFlightChunks = maximumInFlightChunks
        self.maximumRetryDelay = maximumRetryDelay
    }
}

public enum TransferSendAdmission: Equatable, Sendable {
    case admitted
    case alreadyInFlight
    case windowFull
    case retryAfter(Date)
    case cancelled
}

public struct TransferSendProgress: Equatable, Sendable {
    public let inFlightChunks: Int
    public let acknowledgedChunks: Int
    public let retryAfter: Date?
    public let isCancelled: Bool
}

public actor TransferBackpressureController {
    public typealias Clock = @Sendable () -> Date
    public let policy: TransferBackpressurePolicy
    private let clock: Clock
    private var inFlight: Set<UInt32> = []
    private var acknowledged: Set<UInt32> = []
    private var retryAfter: Date?
    private var cancelled = false

    public init(policy: TransferBackpressurePolicy = TransferBackpressurePolicy(), clock: @escaping Clock = Date.init) {
        self.policy = policy
        self.clock = clock
    }

    public func admit(chunkIndex: UInt32) -> TransferSendAdmission {
        guard !cancelled else { return .cancelled }
        let now = clock()
        if let retryAfter, retryAfter > now { return .retryAfter(retryAfter) }
        if retryAfter != nil { self.retryAfter = nil }
        guard !inFlight.contains(chunkIndex) else { return .alreadyInFlight }
        guard !acknowledged.contains(chunkIndex) else { return .alreadyInFlight }
        guard inFlight.count < policy.maximumInFlightChunks else { return .windowFull }
        inFlight.insert(chunkIndex)
        return .admitted
    }

    public func acknowledge(chunkIndex: UInt32) {
        guard inFlight.remove(chunkIndex) != nil else { return }
        acknowledged.insert(chunkIndex)
    }

    public func fail(chunkIndex: UInt32) { inFlight.remove(chunkIndex) }

    public func applyReceiverPressure(retryAfterMilliseconds: UInt32) {
        let bounded = min(TimeInterval(retryAfterMilliseconds) / 1_000, policy.maximumRetryDelay)
        retryAfter = clock().addingTimeInterval(bounded)
    }

    public func cancel() { cancelled = true; inFlight.removeAll(); retryAfter = nil }

    public func progress() -> TransferSendProgress {
        .init(inFlightChunks: inFlight.count, acknowledgedChunks: acknowledged.count,
              retryAfter: retryAfter, isCancelled: cancelled)
    }
}
