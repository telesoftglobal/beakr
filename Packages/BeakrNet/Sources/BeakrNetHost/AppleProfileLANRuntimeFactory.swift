#if canImport(Network) && canImport(Security)
import Foundation
import Network
import Security
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

public enum AppleProfileLANRuntimeFactoryError: Error, Equatable, Sendable {
    case identityUnavailable
    case credentialUnavailable
    case tlsIdentityUnavailable
    case profileIdentityMismatch
    case certificateChainUnavailable
    case invalidAdvertisementNonce
    case invalidServiceType
}

public struct AppleProfileLANRuntimeFactory {
    public static func make(
        profile: NetworkProfile,
        keychainBaseService: String,
        environment: String,
        trustedAuthorityPublicKey: Data,
        revocationSnapshot: CredentialRevocationSnapshot,
        registry: ProfileConnectionRegistry,
        serviceType: String = "_beakrnet._tcp",
        domain: String? = nil,
        advertisementNonce: Data,
        displayName: String? = nil,
        sessionID: @escaping @Sendable (NodeID) async -> SessionID?,
        acceptedPeer: @escaping ProfileAcceptedPeerResolver,
        bonjourDiagnosticSink: @escaping BonjourDiagnosticSink = { _ in },
        transportDiagnosticSink: @escaping LANTransportDiagnosticSink = { _ in },
        runtimeDiagnosticSink: @escaping @Sendable (ProfileBonjourRuntimeDiagnostic) -> Void = { _ in }
    ) throws -> ProfileBonjourRuntimeService {
        guard advertisementNonce.count == 32 else {
            throw AppleProfileLANRuntimeFactoryError.invalidAdvertisementNonce
        }
        guard serviceType.hasPrefix("_"), serviceType.hasSuffix("._tcp") else {
            throw AppleProfileLANRuntimeFactoryError.invalidServiceType
        }

        let namespace = ProfileKeychainNamespace(
            baseService: keychainBaseService,
            profileID: profile.id
        )
        let identity = try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate()
        guard identity.nodeID == profile.localNodeID else {
            throw AppleProfileLANRuntimeFactoryError.profileIdentityMismatch
        }
        guard let credential = try KeychainNodeCredentialStore(namespace: namespace).load(for: profile) else {
            throw AppleProfileLANRuntimeFactoryError.credentialUnavailable
        }
        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            networkID: profile.networkID,
            environment: environment
        )
        guard let tlsIdentity = try KeychainLANTLSIdentityStore(namespace: namespace).load() else {
            throw AppleProfileLANRuntimeFactoryError.tlsIdentityUnavailable
        }
        guard !tlsIdentity.certificateChain.isEmpty else {
            throw AppleProfileLANRuntimeFactoryError.certificateChainUnavailable
        }

        let trustPolicy = LANTLSTrustPolicy.production(
            authorityCertificates: tlsIdentity.certificateChain
        )
        let initiatorParameters = try LANTLSConfiguration.parameters(
            localIdentity: tlsIdentity.identity,
            role: .initiator,
            trustPolicy: trustPolicy
        )
        let acceptorParameters = try LANTLSConfiguration.parameters(
            localIdentity: tlsIdentity.identity,
            role: .acceptor,
            trustPolicy: trustPolicy
        )
        let endpoints = NetworkBonjourEndpointRegistry()
        let browser = NetworkBonjourBrowser(
            serviceType: serviceType,
            domain: domain,
            registry: endpoints
        )
        let connectionFactory = NetworkBonjourConnectionFactory(
            registry: endpoints,
            parameters: { initiatorParameters }
        )
        let listener = try NetworkBonjourListener(
            parameters: acceptorParameters,
            serviceType: serviceType,
            domain: domain,
            metadata: BonjourDiscoveryMetadata(
                nodeIDHint: profile.localNodeID,
                advertisementNonce: advertisementNonce,
                displayName: displayName
            )
        )
        let leafDER = SecCertificateCopyData(tlsIdentity.leafCertificate) as Data
        let lanConfiguration = LANTransportConfiguration(
            identity: identity,
            credential: credential,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            networkID: profile.networkID,
            environment: environment,
            revocationSnapshot: revocationSnapshot,
            localCertificateDER: leafDER,
            localCertificatePublicKey: identity.publicKeyRepresentation,
            capabilities: TransportCapabilities(
                preservesOrder: true,
                supportsImmediateDelivery: true,
                supportsQueuedDelivery: true,
                supportsBackgroundDelivery: false
            )
        )
        let connections = ProfileLANConnectionController(
            registry: registry,
            configuration: lanConfiguration,
            diagnosticSink: transportDiagnosticSink
        )
        return ProfileBonjourRuntimeService.make(
            localNodeID: profile.localNodeID,
            localAdvertisementNonce: advertisementNonce,
            browser: browser,
            connectionFactory: connectionFactory,
            listener: listener,
            connections: connections,
            sessionID: sessionID,
            acceptedPeer: acceptedPeer,
            bonjourDiagnosticSink: bonjourDiagnosticSink,
            diagnosticSink: runtimeDiagnosticSink
        )
    }
}
#endif
