import CryptoKit
import Foundation

public actor LocalAuthorizationGrantAuthority: LocalAuthorizationVerifying {
    private let key: SymmetricKey
    private let maximumValidity: TimeInterval

    public init(maximumValidity: TimeInterval = 60) {
        precondition(maximumValidity > 0 && maximumValidity <= 60)
        key = SymmetricKey(size: .bits256)
        self.maximumValidity = maximumValidity
    }

    public func issue(
        requestID: UUID,
        validity: TimeInterval = 30,
        now: Date = Date()
    ) throws -> LocalAuthorizationGrant {
        guard validity > 0 && validity <= maximumValidity else {
            throw LocalAuthorizationGrantError.invalidValidity
        }
        let issued = milliseconds(now)
        let expires = issued + Int64(validity * 1_000)
        let token = Data(HMAC<SHA256>.authenticationCode(
            for: transcript(requestID: requestID, issued: issued, expires: expires),
            using: key
        ))
        return LocalAuthorizationGrant(
            requestID: requestID,
            issuedAtMilliseconds: issued,
            expiresAtMilliseconds: expires,
            opaqueToken: token
        )
    }

    public func verifyApprovalGrant(
        _ grant: LocalAuthorizationGrant,
        requestID: UUID,
        now: Date
    ) throws {
        let current = milliseconds(now)
        guard grant.requestID == requestID,
              grant.issuedAtMilliseconds <= current,
              grant.expiresAtMilliseconds > current,
              grant.expiresAtMilliseconds - grant.issuedAtMilliseconds
                <= Int64(maximumValidity * 1_000) else {
            throw LocalAuthorizationGrantError.invalidGrant
        }
        let message = transcript(
            requestID: requestID,
            issued: grant.issuedAtMilliseconds,
            expires: grant.expiresAtMilliseconds
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            grant.opaqueToken,
            authenticating: message,
            using: key
        ) else {
            throw LocalAuthorizationGrantError.invalidGrant
        }
    }

    private func transcript(requestID: UUID, issued: Int64, expires: Int64) -> Data {
        Data("BeakrNet local approval v1\0\(requestID.uuidString.lowercased())\0\(issued)\0\(expires)".utf8)
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

public enum LocalAuthorizationGrantError: Error, Equatable, Sendable {
    case invalidValidity
    case invalidGrant
}
