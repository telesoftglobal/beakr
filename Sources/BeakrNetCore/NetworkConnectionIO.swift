#if canImport(Network)
import Foundation
import Network

public enum NetworkConnectionIOError: Error, Sendable {
    case connectionClosed
    case incompleteFrame
}

public enum NetworkConnectionIO {
    public static func send(
        _ message: RelayWireMessage,
        over connection: NWConnection
    ) async throws {
        let frame = try RelayWireCodec.encode(message)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public static func receive(from connection: NWConnection) async throws -> RelayWireMessage {
        let header = try await receiveExactly(
            MemoryLayout<UInt32>.size,
            from: connection
        )
        let bodyLength = try RelayWireCodec.bodyLength(from: header)
        let body = try await receiveExactly(bodyLength, from: connection)
        return try RelayWireCodec.decodeBody(body)
    }

    private static func receiveExactly(
        _ byteCount: Int,
        from connection: NWConnection
    ) async throws -> Data {
        var result = Data()
        while result.count < byteCount {
            let remaining = byteCount - result.count
            let chunk = try await receiveChunk(maximumLength: remaining, from: connection)
            guard !chunk.isEmpty else {
                throw NetworkConnectionIOError.incompleteFrame
            }
            result.append(chunk)
        }
        return result
    }

    private static func receiveChunk(
        maximumLength: Int,
        from connection: NWConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: NetworkConnectionIOError.connectionClosed)
                } else {
                    continuation.resume(throwing: NetworkConnectionIOError.incompleteFrame)
                }
            }
        }
    }
}
#endif
