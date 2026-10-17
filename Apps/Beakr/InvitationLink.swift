import Foundation

enum InvitationLink {
    static let host = "join.beakr.app"

    static func url(for invitation: String) -> URL? {
        let token = Data(invitation.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return URL(string: "https://\(host)/invite/\(token)")
    }

    static func invitation(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.pathComponents.count == 3,
              url.pathComponents[1] == "invite" else {
            return nil
        }

        var token = url.pathComponents[2]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - token.count % 4) % 4
        token.append(String(repeating: "=", count: paddingCount))

        guard let data = Data(base64Encoded: token),
              let invitation = String(data: data, encoding: .utf8) else {
            return nil
        }
        return invitation
    }

    static func invitation(from payload: String) -> String {
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedPayload),
              let invitation = invitation(from: url) else {
            return trimmedPayload
        }
        return invitation
    }
}
