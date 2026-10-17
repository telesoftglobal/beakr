import Foundation
import BeakrNetAuthority

public struct AuthorityHTTP1Policy: Equatable, Sendable {
    public let maximumHeaderBytes: Int
    public let maximumBodyBytes: Int

    public init(maximumHeaderBytes: Int = 16_384, maximumBodyBytes: Int = 262_144) {
        precondition(maximumHeaderBytes > 0 && maximumBodyBytes > 0)
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }
}

public enum AuthorityHTTP1CodecError: Error, Equatable, Sendable {
    case incomplete
    case headerTooLarge
    case bodyTooLarge
    case malformed
    case unsupportedTransferEncoding
    case conflictingContentLength
}

public enum AuthorityHTTP1Codec {
    public static func decodeRequest(
        _ data: Data,
        policy: AuthorityHTTP1Policy = .init()
    ) throws -> CertificateEnrollmentHTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: separator) else {
            if data.count > policy.maximumHeaderBytes { throw AuthorityHTTP1CodecError.headerTooLarge }
            throw AuthorityHTTP1CodecError.incomplete
        }
        let headerData = data[..<boundary.lowerBound]
        guard headerData.count <= policy.maximumHeaderBytes,
              let headerText = String(data: headerData, encoding: .utf8) else {
            throw AuthorityHTTP1CodecError.headerTooLarge
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw AuthorityHTTP1CodecError.malformed }
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count == 3, components[2] == "HTTP/1.1",
              !components[0].isEmpty, components[1].first == "/",
              !components[1].contains("#") else { throw AuthorityHTTP1CodecError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw AuthorityHTTP1CodecError.malformed }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
                  headers[name] == nil else { throw AuthorityHTTP1CodecError.malformed }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            throw AuthorityHTTP1CodecError.unsupportedTransferEncoding
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else {
                throw AuthorityHTTP1CodecError.conflictingContentLength
            }
            length = parsed
        } else {
            length = 0
        }
        guard length <= policy.maximumBodyBytes else { throw AuthorityHTTP1CodecError.bodyTooLarge }
        let bodyStart = boundary.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= length else { throw AuthorityHTTP1CodecError.incomplete }
        guard available == length else { throw AuthorityHTTP1CodecError.malformed }
        return .init(
            method: String(components[0]),
            path: String(components[1]),
            headers: headers,
            body: Data(data[bodyStart...])
        )
    }

    public static func encodeResponse(_ response: CertificateEnrollmentHTTPResponse) -> Data {
        let reason: String = switch response.statusCode {
        case 200: "OK"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
        var headers = response.headers
        headers["content-length"] = String(response.body.count)
        headers["connection"] = "close"
        var text = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8) + response.body
    }
}
