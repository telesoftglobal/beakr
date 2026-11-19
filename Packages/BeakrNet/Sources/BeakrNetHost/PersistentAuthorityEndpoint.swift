import Foundation
import BeakrNetCore
import BeakrNetAuthority

public enum AuthorityEndpointPersistenceError: Error, Equatable, Sendable {
    case generationExhausted
    case conflictingEndpoint
    case olderPublication
    case conflictingPublication
}

/// One writer per authority storage path. Persist before exposing a publication.
/// A missing file is first use; a malformed or wrongly bound file fails closed.
public actor PersistentAuthorityEndpointPublisher {
    private let fileURL: URL
    private let authority: CredentialAuthority
    private let networkID: NetworkID
    private let environment: String
    private var latest: SignedAuthorityEndpoint?

    private init(
        fileURL: URL, authority: CredentialAuthority, networkID: NetworkID,
        environment: String, latest: SignedAuthorityEndpoint?
    ) {
        self.fileURL = fileURL
        self.authority = authority
        self.networkID = networkID
        self.environment = environment
        self.latest = latest
    }

    public static func open(
        fileURL: URL, authority: CredentialAuthority, networkID: NetworkID, environment: String
    ) throws -> PersistentAuthorityEndpointPublisher {
        let latest = try AuthorityEndpointFile.read(
            fileURL, publicKey: authority.publicKeyRepresentation,
            networkID: networkID, environment: environment
        )
        return PersistentAuthorityEndpointPublisher(
            fileURL: fileURL, authority: authority, networkID: networkID,
            environment: environment, latest: latest
        )
    }

    public func publish(
        hostname: String, boundPort: UInt16, validity: TimeInterval = 120, now: Date = Date()
    ) throws -> SignedAuthorityEndpoint {
        // DNS names are case-insensitive; signed claims use a canonical spelling.
        // Normalize before comparing generations as well as before signing.
        let hostname = hostname.lowercased()
        var generation: UInt64 = latest?.claims.generation ?? 1
        if let previous = latest,
           previous.claims.hostname != hostname || previous.claims.port != boundPort {
            let next = generation.addingReportingOverflow(1)
            guard !next.overflow else { throw AuthorityEndpointPersistenceError.generationExhausted }
            generation = next.partialValue
        }
        let record = try authority.issueAuthorityEndpoint(
            networkID: networkID, environment: environment, hostname: hostname,
            port: boundPort, generation: generation, validity: validity, now: now
        )
        if let latest {
            try AuthorityEndpointOrdering.validate(record.claims, after: latest.claims)
            if record.claims == latest.claims { return latest }
        }
        try AuthorityEndpointFile.write(record, to: fileURL)
        latest = record
        return record
    }
}

/// Keeps signed high-water evidence even after expiry so a restart cannot
/// authorize an older endpoint. Expired records are never returned as routes.
public actor PersistentAuthorityEndpointCache {
    private let fileURL: URL
    private let publicKey: Data
    private let networkID: NetworkID
    private let environment: String
    private var latest: SignedAuthorityEndpoint?

    private init(
        fileURL: URL, publicKey: Data, networkID: NetworkID,
        environment: String, latest: SignedAuthorityEndpoint?
    ) {
        self.fileURL = fileURL
        self.publicKey = publicKey
        self.networkID = networkID
        self.environment = environment
        self.latest = latest
    }

    public static func open(
        fileURL: URL, trustedAuthorityPublicKey: Data, networkID: NetworkID, environment: String
    ) throws -> PersistentAuthorityEndpointCache {
        let latest = try AuthorityEndpointFile.read(
            fileURL, publicKey: trustedAuthorityPublicKey, networkID: networkID, environment: environment
        )
        return PersistentAuthorityEndpointCache(
            fileURL: fileURL, publicKey: trustedAuthorityPublicKey,
            networkID: networkID, environment: environment, latest: latest
        )
    }

    @discardableResult
    public func accept(
        _ record: SignedAuthorityEndpoint, now: Date = Date()
    ) throws -> VerifiedAuthorityEndpoint {
        let verified = try AuthorityEndpointVerifier.verify(
            record, trustedAuthorityPublicKey: publicKey, networkID: networkID,
            environment: environment, minimumGeneration: latest?.claims.generation ?? 0, now: now
        )
        if let latest {
            try AuthorityEndpointOrdering.validate(record.claims, after: latest.claims)
            if record.claims == latest.claims { return verified }
        }
        try AuthorityEndpointFile.write(record, to: fileURL)
        latest = record
        return verified
    }

    public func current(now: Date = Date()) throws -> VerifiedAuthorityEndpoint? {
        guard let latest else { return nil }
        do {
            return try AuthorityEndpointVerifier.verify(
                latest, trustedAuthorityPublicKey: publicKey,
                networkID: networkID, environment: environment, now: now
            )
        } catch AuthorityEndpointError.expired {
            return nil
        } catch AuthorityEndpointError.issuedInFuture {
            return nil
        }
    }
}

private enum AuthorityEndpointOrdering {
    static func validate(_ candidate: AuthorityEndpointClaims, after previous: AuthorityEndpointClaims) throws {
        guard candidate.generation >= previous.generation else {
            throw AuthorityEndpointError.staleGeneration
        }
        guard candidate.issuedAtMilliseconds >= previous.issuedAtMilliseconds else {
            throw AuthorityEndpointPersistenceError.olderPublication
        }
        if candidate.generation == previous.generation {
            guard candidate.hostname == previous.hostname, candidate.port == previous.port else {
                throw AuthorityEndpointPersistenceError.conflictingEndpoint
            }
            guard candidate.expiresAtMilliseconds >= previous.expiresAtMilliseconds else {
                throw AuthorityEndpointPersistenceError.olderPublication
            }
            if candidate.issuedAtMilliseconds == previous.issuedAtMilliseconds,
               candidate.expiresAtMilliseconds != previous.expiresAtMilliseconds {
                throw AuthorityEndpointPersistenceError.conflictingPublication
            }
        }
    }
}

private enum AuthorityEndpointFile {
    static func read(
        _ url: URL, publicKey: Data, networkID: NetworkID, environment: String
    ) throws -> SignedAuthorityEndpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_097) ?? Data()
        let record = try SignedAuthorityEndpoint.decode(data)
        try AuthorityEndpointVerifier.verifyAuthenticity(
            record, trustedAuthorityPublicKey: publicKey, networkID: networkID, environment: environment
        )
        return record
    }

    static func write(_ record: SignedAuthorityEndpoint, to url: URL) throws {
        let data = try record.encoded()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
