import Foundation
import Testing
import BeakrNetTransfer

@Suite("Transfer sender backpressure")
struct TransferBackpressureTests {
    @Test("The in-flight window is strict and acknowledgements release capacity")
    func boundedWindow() async {
        let controller = TransferBackpressureController(policy: .init(maximumInFlightChunks: 2, maximumRetryDelay: 10))
        #expect(await controller.admit(chunkIndex: 0) == .admitted)
        #expect(await controller.admit(chunkIndex: 1) == .admitted)
        #expect(await controller.admit(chunkIndex: 2) == .windowFull)
        #expect(await controller.admit(chunkIndex: 1) == .alreadyInFlight)
        await controller.acknowledge(chunkIndex: 0)
        #expect(await controller.admit(chunkIndex: 2) == .admitted)
        #expect(await controller.progress().acknowledgedChunks == 1)
    }

    @Test("Receiver retry delays are capped and deterministic")
    func retryDelay() async {
        let clock = MutableTransferClock(Date(timeIntervalSince1970: 1_000))
        let controller = TransferBackpressureController(
            policy: .init(maximumInFlightChunks: 1, maximumRetryDelay: 5), clock: { clock.now }
        )
        await controller.applyReceiverPressure(retryAfterMilliseconds: 60_000)
        #expect(await controller.admit(chunkIndex: 0) == .retryAfter(Date(timeIntervalSince1970: 1_005)))
        clock.now = Date(timeIntervalSince1970: 1_006)
        #expect(await controller.admit(chunkIndex: 0) == .admitted)
        await controller.cancel()
        #expect(await controller.admit(chunkIndex: 1) == .cancelled)
        #expect(await controller.progress().inFlightChunks == 0)
    }
}

private final class MutableTransferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
