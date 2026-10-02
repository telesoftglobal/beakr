import Foundation

public enum RelayWireMessage: Codable, Equatable, Sendable {
    case clientHello(nodeID: NodeID, publicKey: Data)
    case serverChallenge(Data)
    case clientProof(Data)
    case registrationAccepted(nodeID: NodeID)
    case registrationRejected
    case envelope(BeakrNetEnvelope)
}

public enum RelayWireCodecError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case invalidLength
}

public enum RelayWireCodec {
    public static let maximumFrameLength = 1_048_576

    public static func encode(_ message: RelayWireMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maximumFrameLength else {
            throw RelayWireCodecError.frameTooLarge(body.count)
        }

        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        return frame
    }

    public static func decodeBody(_ body: Data) throws -> RelayWireMessage {
        guard !body.isEmpty, body.count <= maximumFrameLength else {
            throw RelayWireCodecError.invalidLength
        }
        return try JSONDecoder().decode(RelayWireMessage.self, from: body)
    }

    public static func bodyLength(from header: Data) throws -> Int {
        guard header.count == MemoryLayout<UInt32>.size else {
            throw RelayWireCodecError.invalidLength
        }
        let value = header.reduce(UInt32.zero) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let length = Int(value)
        guard length > 0, length <= maximumFrameLength else {
            throw RelayWireCodecError.invalidLength
        }
        return length
    }
}
