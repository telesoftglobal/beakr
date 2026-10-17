import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetOperations

@Suite("Bounded authority HTTP/1.1 codec")
struct AuthorityHTTP1CodecTests {
    @Test("A canonical request decodes and response encoding is deterministic")
    func roundTripBoundary() throws {
        let request = Data("GET /v1/profile-membership HTTP/1.1\r\nAccept: application/json\r\n\r\n".utf8)
        let decoded = try AuthorityHTTP1Codec.decodeRequest(request)
        #expect(decoded.method == "GET")
        #expect(decoded.path == "/v1/profile-membership")
        #expect(decoded.headers["accept"] == "application/json")

        let encoded = AuthorityHTTP1Codec.encodeResponse(.init(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("{}".utf8)
        ))
        #expect(String(decoding: encoded, as: UTF8.self) ==
            "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\ncontent-type: application/json\r\n\r\n{}")
    }

    @Test("Incomplete, oversized, chunked, duplicate, and trailing requests fail closed")
    func rejectsInvalidFraming() {
        #expect(throws: AuthorityHTTP1CodecError.incomplete) {
            try AuthorityHTTP1Codec.decodeRequest(Data("GET / HTTP/1.1\r\n".utf8))
        }
        #expect(throws: AuthorityHTTP1CodecError.headerTooLarge) {
            try AuthorityHTTP1Codec.decodeRequest(
                Data("GET / HTTP/1.1\r\nX: 123456789\r\n\r\n".utf8),
                policy: .init(maximumHeaderBytes: 16, maximumBodyBytes: 10)
            )
        }
        #expect(throws: AuthorityHTTP1CodecError.unsupportedTransferEncoding) {
            try AuthorityHTTP1Codec.decodeRequest(Data(
                "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
            ))
        }
        #expect(throws: AuthorityHTTP1CodecError.malformed) {
            try AuthorityHTTP1Codec.decodeRequest(Data(
                "GET / HTTP/1.1\r\nX: 1\r\nx: 2\r\n\r\n".utf8
            ))
        }
        #expect(throws: AuthorityHTTP1CodecError.malformed) {
            try AuthorityHTTP1Codec.decodeRequest(Data(
                "POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\n12".utf8
            ))
        }
    }
}
