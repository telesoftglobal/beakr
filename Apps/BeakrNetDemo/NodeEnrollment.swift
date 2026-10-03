import BeakrNetCore
import BeakrNetSecurity
import Foundation

struct NodeEnrollmentPayload: Codable, Equatable {
    let type: String
    let version: Int
    let displayName: String
    let nodeID: String
    let publicKeyBase64: String

    init(displayName: String, nodeID: String, publicKeyBase64: String) {
        self.type = "net.beakr.node-enrollment"
        self.version = 1
        self.displayName = displayName
        self.nodeID = nodeID
        self.publicKeyBase64 = publicKeyBase64
    }

    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decodeAndValidate(_ string: String) throws -> NodeEnrollmentPayload {
        let payload = try JSONDecoder().decode(
            NodeEnrollmentPayload.self,
            from: Data(string.utf8)
        )
        guard payload.type == "net.beakr.node-enrollment",
              payload.version == 1,
              let nodeUUID = UUID(uuidString: payload.nodeID),
              let publicKey = Data(base64Encoded: payload.publicKeyBase64),
              NodeIdentity.nodeID(forPublicKeyRepresentation: publicKey).rawValue == nodeUUID else {
            throw NodeEnrollmentError.invalidPayload
        }
        return payload
    }
}

enum NodeEnrollmentError: Error {
    case invalidPayload
}
