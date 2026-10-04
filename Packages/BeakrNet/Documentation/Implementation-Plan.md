# BeakrNet Implementation Plan

This document begins the implementation phase after the architecture and terminology discussions recorded in `Architecture.md`, `Channel-Model.md`, and `Beakr-System-Architecture.md`.

## Starting point

Begin with one narrow milestone:

> Make channel semantics explicit and enforceable in BeakrNetCore without changing transports yet.

The current envelope contains identity, sequence, payload type, and payload, but it has no explicit channel or delivery semantics.

## Milestone 1: Versioned channel contract

**Status: Complete.** BeakrNetCore now implements the version-2 channel contract, validates envelopes at session ingress and before pending-delivery enqueue, and exercises mixed Control and Data traffic through the handoff lab.

The implemented contract makes these deliberate choices:

- Schema version 1 is rejected rather than inferred or migrated. Version 1 did not carry enough information to recover channel semantics safely.
- Control payloads use the reserved `beakrnet.*` namespace and are limited to 16 KiB.
- Control delivery is ephemeral or queued for no more than five minutes; it is never durable.
- Replacement keys are valid only for queued delivery.
- Channel and representation are immutable envelope metadata. Transports carry them without reclassification.

Introduce core value types along these lines:

```swift
public enum BeakrNetChannel: String, Codable, Sendable {
    case control
    case data
    case blackboard
}

public enum RepresentationProfile: String, Codable, Sendable {
    case full
    case compact
}

public enum DeliveryDurability: String, Codable, Sendable {
    case ephemeral
    case queued
    case durable
}

public struct DeliveryPolicy: Codable, Equatable, Sendable {
    public let durability: DeliveryDurability
    public let priority: UInt8
    public let expiresAt: Date?
    public let replacementKey: String?
}
```

Extend `BeakrNetEnvelope` with explicit channel, representation, and delivery-policy metadata.

Do not add WatchConnectivity, Bluetooth, storage, or route-selection code in this milestone.

## Protect the Control channel

Introduce envelope validation with rules including:

- Control payload types use a reserved `beakrnet.*` namespace.
- Application-defined payloads cannot use Control.
- Control envelopes have a strict size limit.
- Control is ephemeral or briefly queued, not application-durable.
- Control cannot carry arbitrary files or application state.
- Data and Blackboard cannot be silently reclassified by a transport.

Potential validation errors include:

```swift
public enum EnvelopeValidationError: Error {
    case unsupportedSchemaVersion
    case applicationPayloadOnControlChannel
    case controlPayloadTooLarge
    case invalidDeliveryPolicy
    case expired
}
```

Validate envelopes before they enter the pending-delivery queue and before incoming envelopes are accepted into a session.

## Initial Control vocabulary

Start with a small reserved protocol vocabulary:

- Delivery acknowledgement
- Capability advertisement
- Protocol-version negotiation
- Route availability
- Session keepalive or liveness
- Queue-pressure indication

`DeliveryAcknowledgement` should become an explicit Control payload rather than relying only on its payload-type string.

Application actions remain Data even when their encoded payload is small:

```text
beakrnet.delivery-acknowledgement → Control
beakrnet.capabilities             → Control
com.example.turn-light-on         → Data
com.example.watch-notification    → Data + compact
```

## Protocol versioning

The current envelope declares schema version 1. Adding required metadata changes the wire contract.

For this experimental stage:

1. Introduce envelope schema version 2.
2. Encode the new fields explicitly.
3. Reject unsupported future versions clearly.
4. Define version-1 decoding behavior deliberately rather than relying on synthesized `Codable`.
5. Add golden encoded fixtures so accidental wire-format changes are visible.

The automatically encoded `RelayWireMessage` enum should eventually receive an explicit stable wire representation, but that work follows the envelope contract.

## Required tests

Add tests proving:

- Each channel survives encode and decode.
- Version-2 envelopes round-trip.
- Unsupported versions are rejected.
- Application payloads cannot enter Control.
- Oversized Control envelopes are rejected.
- Compact Data remains Data.
- Compact Blackboard state remains Blackboard.
- Expired messages are rejected or removed.
- Replacement keys are allowed only with an appropriate policy.
- Session deduplication continues across transport handoff.
- A transport cannot alter an envelope’s channel.

Then update `BeakrNetHandoffLab` to send a mixture of Control and Data while replacing transports.

## Implementation sequence

1. Core channel and policy types
2. Envelope schema version 2
3. Envelope validation
4. Reserved Control payload definitions
5. Session integration
6. Codec and compatibility tests
7. Mixed-channel handoff lab
8. Relay scheduling with reserved Control capacity — complete
9. Persistent queues — complete
10. Bonjour/direct-LAN transport and route selection

Structured diagnostics should accompany these changes. Datastores, external APIs, rules, MCP, Siri, WatchConnectivity, and Bluetooth remain outside the first milestone.

## First coding task

Implement and test the version-2 envelope contract in `BeakrNetCore`.

Completed. The package test suite includes a stable JSON fixture for schema version 2, compatibility rejection tests, channel and policy validation tests, session-boundary validation, and transport-preservation coverage. `BeakrNetHandoffLab` carries mixed Control and Data envelopes across relay/local/relay handoff while preserving deduplication.

## Milestone 2: Relay scheduling with reserved Control capacity

**Status: Complete.** The in-memory bounded relay queue partitions each destination into Control and application traffic while retaining one combined per-node and global bound.

- Reservation limits cap Data and Blackboard occupancy, leaving configured per-node and global slots available to Control.
- A Control enqueue may use any remaining slot. Under full pressure, eviction prefers the oldest application envelope before evicting Control.
- Data and Blackboard share the application partition and retain FIFO order. When their partition is full, admission evicts the oldest application envelope rather than consuming reserved capacity.
- Drain scheduling gives Control preferential service but emits one application envelope after a configurable maximum Control burst, preventing application starvation.
- Admission reports every eviction and its per-node or global cause. A diagnostics snapshot reports current partition counts plus cumulative admissions, evictions, and expirations.
- Queue expiry remains in-memory and uses the existing relay TTL. The envelope's immutable channel selects its partition; the relay never reclassifies it.

Persistent queues are addressed by Milestone 3. New transports, application storage, rules, and UI remain out of scope.

## Milestone 3: Persistent relay queues

**Status: Complete.** The relay now uses a file-backed queue that preserves Milestone 2 admission and scheduling behavior across process restarts.

- `PersistentRelayQueue` composes the existing `BoundedRelayQueue`, keeping one source of truth for per-node/global bounds, reserved Control capacity, eviction preference, expiry, and bounded-burst scheduling.
- A versioned JSON snapshot records destination, envelope, and original enqueue time. Each successful enqueue or drain atomically replaces the snapshot.
- Recovery rejects unknown snapshot format versions, restores entries in enqueue order, applies the configured TTL, and persists the cleaned state.
- The relay server opens the persistent queue before accepting connections. `BEAKRNET_RELAY_QUEUE_FILE` selects its location; otherwise `BeakrNetRelayQueue.json` in the working directory is used.
- Focused tests cover restart recovery, fair Control/application scheduling after recovery, reserved Control capacity under persistent admission, durable drain removal, and expiry during restart.

The snapshot deliberately excludes application data stores, rules, UI state, route selection, and transport-specific behavior. Diagnostic event counters remain process-local. Relay-to-client acknowledgement or queue leasing would change the wire protocol and is deferred; the current drain operation durably removes its batch before returning it for network delivery.

## Milestone 4: Authenticated direct-LAN transport and route selection

**Status: Complete.** The architecture, transport, handoff lab, package integration target, and signed Apple-platform test host cover discovery, deterministic connection ownership, TLS 1.3 mutual authentication, application-layer mutual authentication, capability negotiation, bounded envelope framing, route ordering, make-before-break promotion, ambiguous-send recovery over relay, cross-route acknowledgement, diagnostics, rejection cases, and clean teardown. See `Architecture.md`, `Security-Model.md`, and `Apple-Network-Integration-Tests.md`.

The selected platform direction is Bonjour through `NWBrowser` and `NWListener`, retaining discovered service endpoints for `NWConnection`. Bonjour metadata is only an untrusted hint. Direct LAN is preferred over relay only after the secure channel, credential verification, proof of possession, and capability negotiation succeed. Relay stays connected and remains the queued/persistent fallback.

Do not implement the Network transport yet. The current relay TLS PSK is a shared development secret and is not an acceptable per-peer LAN identity or authorization mechanism. The resolved security profile is:

1. Mutual TLS 1.3 uses per-node P-256 certificates whose key exactly matches the authority-signed node credential; development leaves are self-signed and production leaves are enrollment-issued, both with a maximum 30-day lifetime.
2. Network-framework evaluation does not use Bonjour names as DNS identities. Development trust is provisional and production additionally requires the configured certificate authority; neither becomes eligible until the signed handshake verifies exact certificate/credential key binding and both leaf fingerprints.
3. Offline authentication fails closed when the signed revocation snapshot is more than 24 hours old, and a newly installed snapshot immediately disconnects a now-revoked LAN peer.
4. The initial complete encoded-envelope limit is 1 MiB, rejected before allocation and negotiated downward. Raising it requires device memory and framing measurements.

Recommended implementation sequence after those decisions:

1. Extend `TransportCapabilities` with channels, representations, maximum envelope bytes, immediate/queued/background behavior, and protocol version; add compatibility tests. — complete
2. Add pure `RouteCandidate`, `RouteSelector`, route generation, and structured diagnostic types in BeakrNetCore. Test deterministic LAN-over-relay preference and stable tie-breaking. — complete
3. Add a per-peer route coordinator that owns eligibility and make-before-break transitions but not pending messages. Inject clock, scheduler, and event sink. — complete; the coordinator has no timer-driven behavior, so only its event sink is required
4. Add a session delivery driver that queues once, snapshots route generation, records each attempt, retries the identical Message ID after ambiguous failure, accepts acknowledgements on any route, and observes expiry. — complete
5. Define an explicit versioned LAN handshake wire format and domain-separated transcript in BeakrNetSecurity. Add credential, role, nonce, replay, scope, capability-binding, and revocation tests. — complete
6. Implement injected Network-framework adapters for browser, listener, and connection. Keep TXT parsing and discovery-state handling separate from authentication. — complete
7. Add authenticated `LANTransport`, integration tests on loopback, and scripted tests for permission denial and path loss. — complete
8. Extend the handoff lab to run relay → authenticated LAN → relay while one after-write result is ambiguous. Verify one logical session, one application acceptance per Message ID, eventual acknowledgement, and unchanged relay persistence. — complete
9. Run the complete package suite and add an Apple-platform integration job because Bonjour and Network-framework behavior cannot be established by pure unit tests alone. — complete; see `Apple-Network-Integration-Tests.md`

Exit criteria require all security gates resolved, no unauthenticated candidate becoming eligible, deterministic selection under reordered callbacks, relay fallback after LAN failure, and preservation of pending delivery, deduplication, expiry, channel metadata, and Session ID across both promotion and demotion.

### Closure audit

The October 2026 closure audit verified the current slice as follows:

- Credential, environment, scope, expiry, revocation freshness, role, nonce, replay, capability, certificate-key, certificate-fingerprint, and proof checks fail closed before `LANTransport` is returned.
- Route candidates become eligible only after authentication and readiness. Generation tokens reject stale callbacks, and stable selection tests cover reordered discovery and route callbacks.
- LAN failure marks that generation unhealthy and selects the still-ready relay. The delivery driver retains one immutable pending envelope and retries the same Message ID after an ambiguous write.
- Cross-route acknowledgement, receiver duplicate suppression, expiry during handoff, channel and representation metadata, Session ID, and unchanged persistent relay state are covered by unit and handoff-lab tests.
- The opt-in macOS integration target verifies real `NWListener`/`NWBrowser` discovery, TLS establishment, framed Network-framework I/O, the authenticated LAN handshake, envelope delivery, path-loss diagnostics, and teardown.
- The complete deterministic package suite passes independently of Apple networking services.

The signed `BeakrNetDemoIntegrationTests` suite was reported successful on macOS, iOS Simulator, and a physical iPhone on October 3, 2026. These runs covered mutual TLS 1.3, encrypted transfer, wrong-authority rejection, expired-leaf rejection, missing-client-identity rejection, signing and installation, and physical-device Local Network authorization. The reusable `LANTLSConfiguration` constrains TLS to 1.3, installs the local identity, requires peer authentication in both roles, and applies either provisional self-signed development trust or explicit production authority anchors.

Milestone 4 is closed. Certificate enrollment, renewal, authority rotation, and operational revocation propagation belong to the next certificate-lifecycle milestone.

## Milestone 5: Certificate lifecycle

**Status: Complete.**

The first slice defines an authority-scoped, single-use certificate-enrollment challenge and a node-signed request. Its domain-separated canonical transcript binds the request and challenge identifiers, authority, environment, credential, Node ID, exact node public key, nonce, timestamps, and requested lifetime. Validation requires the existing authority credential and LAN scope, enforces challenge freshness and a five-minute maximum challenge lifetime, caps requested certificate validity at 30 days, verifies proof of the enrolled node key, and consumes a challenge only after successful validation.

The second slice adds an authority-signed canonical response binding the request, node identity and key, validity window, leaf DER, and ordered certificate chain. `CertificateEnrollmentService` validates and consumes the request before invoking an injected certificate-material issuer with the exact enrolled key and bounded lifetime, then signs the resulting response. This keeps X.509 authoring behind a platform/CA boundary while making issuance orchestration testable.

The third slice adds a macOS development issuer backed by OpenSSL. It constructs a P-256 SubjectPublicKeyInfo from the enrolled node key, issues client/server-auth leaves without handling the node private key, returns DER leaf and authority chain material, and is covered by an opt-in integration test using an ephemeral real CA.

The fourth slice adds `KeychainLANTLSIdentityStore`. It rejects certificates that do not contain the node's exact public key, stages the private key and complete certificate material before activation, proves the staged `SecIdentity` is loadable, atomically switches an active-material pointer, and only then removes the superseded leaf. A failed replacement therefore retains the prior usable identity. Signed-host integration coverage exercises installation and rollback behavior against the real Apple Keychain.

The fifth slice adds host-driven renewal scheduling from the authority-signed certificate validity window. Renewal begins around two-thirds of the lifetime with bounded per-node jitter. Failures use capped exponential backoff with bounded jitter and an expiry safety margin. Every replacement response is reverified against its exact request, authority, Node ID, and public key before installation; failed or untrusted attempts leave the current response and Keychain identity active.

The sixth slice adds authority rotation. A domain-separated transition statement binds the environment, monotonic generation, predecessor and successor authority identities, successor P-256 public key, issue time, and bounded overlap deadline under the predecessor's signature. Persisted trust state requires exactly sequential generations, accepts credentials, revocation snapshots, and enrollment responses from both authorities only during overlap, and retires the predecessor at the deadline. Devices that miss the overlap fail closed and require an explicitly trusted recovery path rather than accepting a stale transition.

The seventh slice adds the HTTPS enrollment endpoint layer. `POST /v1/certificate-enrollment/challenge` issues a bounded, server-recorded challenge, and `POST /v1/certificate-enrollment` accepts the existing canonical node-signed request and returns the canonical authority-signed response. The handler enforces exact media type, methods, canonical JSON, body limits, generic failure responses, no-store caching, issued-challenge membership, successful-use consumption, and bounded outstanding state. The client requires HTTPS, validates challenge authority and environment before signing, and directly implements the renewal requester contract. Deployment hosts adapt their HTTP server to the transport-neutral handler; TLS termination and rate limits remain host responsibilities.

The eighth slice adds explicit missed-rotation recovery. Recovery uses a separately pinned offline P-256 key, not an operational authority key. A short-lived, domain-separated recovery package binds the environment, strictly increasing target generation, replacement authority identity and key, and validity window. Applying it is an explicit API operation that discards stale predecessor trust rather than creating another overlap. Wrong-key, expired, future-dated, tampered, replayed, non-increasing, and recovery-key-as-operational-authority packages fail closed.

The ninth slice adds operational revocation distribution. `RevocationSnapshotDistributor` verifies every authority-signed snapshot before accepting it, rejects timestamp rollback and conflicting snapshots at the same timestamp, retains the latest verified state, fans it out to every registered authenticated transport, and immediately catches up transports registered later. Per-transport outcomes isolate failures without preventing healthy routes from updating. LAN transports disconnect revoked peers; relay transports configured with the trusted authority key close when their own credential is revoked. The consumer boundary is transport-neutral so hosts can register every active LAN and relay route without coupling authority code to either implementation.

The tenth slice adds the host control-plane boundary. `RevocationRefreshController` restores atomically persisted state at startup, requests updates conditionally from the current snapshot timestamp, verifies each candidate before durable storage, and activates it only after persistence succeeds. Hosts invoke the same refresh operation for scheduled, manual, and push-notification triggers. Success restores the normal refresh cadence; failures use capped exponential retry and retain the active snapshot. Structured diagnostics report trigger, persistence, activation, per-consumer failure count, unchanged responses, and retry scheduling. `FileRevocationSnapshotStore` supplies the production file-backed persistence adapter while request transport remains injectable for deployment-specific HTTPS authentication.

Remote push delivery, background execution entitlement policy, fleet telemetry export, and the concrete production revocation URL remain deployment responsibilities.

The eleventh slice adds the concrete HTTPS revocation contract. `GET /v1/credential-revocations` returns canonical JSON with a media type and strong generation ETag, or `304` for the current generation. The endpoint rejects other paths, methods, and request bodies and prevents snapshot rollback or same-timestamp replacement. `RevocationSnapshotNetworkClient` uses the existing HTTPS-only, same-host, no-redirect URLSession transport, caps response size, requires the exact media type and ETag, rejects noncanonical and non-advancing snapshots, and feeds the verified refresh pipeline. Revocation data is public signed state, so no bearer credential is introduced: TLS authenticates the server and the authority signature authenticates the content.

### Closure audit

The October 2026 closure audit verified:

- Enrollment challenges are server-issued, bounded, single-use, environment- and authority-scoped, and bound into a node-signed request for the exact enrolled key.
- Authority-signed enrollment responses bind request, node, key, validity, leaf, and chain; real development issuance and atomic Keychain replacement have opt-in signed-host coverage.
- Renewal derives its schedule from signed validity, re-verifies every response, uses capped retry, and preserves the active identity on failure.
- Authority transitions are sequential, predecessor-signed, environment-bound, overlap-limited, and persisted canonically; missed overlap requires an explicit separately pinned recovery key.
- Revocation snapshots are signed, freshness-checked for LAN authentication, rollback-protected, durably stored before activation, distributed to active and newly registered routes, and fetched through a strict conditional HTTPS contract.
- A revoked LAN peer is disconnected immediately. A relay client closes when its own credential is revoked. Per-route distribution failure is visible without preventing healthy routes from updating.
- Deterministic unit tests remain independent of network services. Real OpenSSL, Keychain, Bonjour, Network.framework, mutual-TLS, Simulator, and physical-device behavior remains in the opt-in integration layers documented separately.

Milestone 5 is closed. Production deployment still owns authority-key custody, HTTP hosting and rate limits, background execution and push policy, telemetry export, and the selected offline grace window.

WatchConnectivity, Bluetooth Low Energy, application storage, rules, external APIs, and UI remain out of scope through Milestone 5.

## Milestone 6: Typed Control protocol

**Status: Complete.** `BeakrNetControl` now provides canonical independently versioned schemas and bounded dispatch for delivery acknowledgement, session liveness, queue pressure, synchronization hints, and protocol errors. Capability and protocol negotiation remain authoritative in the authenticated handshake; route availability remains advisory.

Create a platform-neutral `BeakrNetControl` library and `BeakrNetControlTests` target inside the existing BeakrNet Swift package. The new library depends on `BeakrNetCore`; transport, security, authority, and application targets do not become dependencies of it. See [Package Architecture and Testing](Package-Architecture-and-Testing.md) for dependency rules, regression boundaries, and validation layers.

Required work includes typed schemas, canonical fixtures, source/destination/session consistency checks, per-message authorization, replay and rate bounds, unknown-version handling, and prevention of acknowledgement loops. Exit requires every accepted `beakrnet.*` payload to have a concrete validated schema and all malformed, unsupported, unauthorized, replayed, and oversized forms to fail closed.

The implementation uses sorted-key canonical JSON and rejects noncanonical input, mismatched envelope context, unknown discriminators, unsupported payload versions, oversized fields and messages, unauthorized sources, bounded replay, and per-source rate excess. Dispatcher diagnostics expose only message identifiers, message type, and safe reason codes. Handler failures are isolated, protocol-error generation is bounded, and acknowledgements and errors cannot cause response loops. Pure tests cover transport/session delivery and mixed Control/Data/Blackboard relay fairness; no additional Apple-specific implementation was required.

## Milestone 7: Application Data protocol

**Status: Complete.** The platform-neutral `BeakrNetData` target provides independently versioned canonical schemas for bounded message, request, response, cancellation, and application-error traffic. Namespaced operation versions, correlation IDs, mutation idempotency keys, deadlines, strict metadata rules, authorization-before-dispatch, supported-operation gating, replay bounds, response-size bounds, privacy-safe diagnostics, and isolated handlers are covered by deterministic tests. `BeakrNetData` depends only on `BeakrNetCore` and `BeakrNetControl`; product operations remain above it.

`PersistentDataState` atomically stores bounded outgoing envelopes and completed incoming Message ID/idempotency results, removes expired outgoing work during recovery, and preserves correlated responses across restart. Cancellation state is bounded and injectable. Handler responses must retain the request operation and correlation and satisfy codec bounds before persistence. An end-to-end deterministic test proves that an ambiguous LAN write retries the identical envelope over relay, is accepted once, invokes one mutation, and retains one correlated response. Application repositories remain responsible for committing their mutation and idempotency record within an application-level transaction when stronger crash atomicity is required. Chunked files and live media remain deferred.

Exit requires a request to retry unchanged across relay/LAN handoff while producing one application mutation and one correlated response. Restart must preserve pending delivery and deduplication, unsupported operations must not reach handlers, and sustained Data traffic must not starve Control.

## Milestone 8: Blackboard replication

**Status: Complete.** [Blackboard Replication Design](Blackboard-Replication-Design.md) defines identifiers, an observed-remove multi-value register, vector-frontier causality, explicit conflicts, application-owned resolution, membership roles, canonical snapshots and journals, generation-bound cursors, compaction safety, tombstone retention, attachment references, subscriptions, and resource bounds. `BeakrBlackboard` implements the canonical bounded protocol, atomic batch dispatch, authorized repositories, deterministic concurrent conflicts, explicit resolution, restart-safe persistence, causal compaction, subscription hints, and unchanged operation identity through relay/LAN handoff. Wall-clock time is never a conflict-resolution rule.

Exit requires deterministic offline-edit convergence or identical explicit conflicts regardless of delivery order, restart-safe snapshot/journal recovery, rollback and invalid-causality rejection, authorization enforcement, and synchronization across route handoff without changing operation identity. Attachments are Data-transfer references rather than Blackboard blobs.

## Milestone 9: Reliable large Data transfer

**Status: Complete.** [Reliable Large Data Transfer Design](Reliable-Transfer-Design.md) defines immutable manifests, SHA-256 commitments, bounded chunks and missing ranges, restart-safe staging, authorization, backpressure, atomic publication, expiry, cancellation, storage pressure, cleanup, diagnostics, and route-independent identity. `BeakrNetTransfer` implements the canonical protocol, digest-verified resumable staging, authorized dispatch, bounded sender windows and retry delays, verified publication, cleanup, relay/LAN continuation, and Control fairness. Live audio and video samples remain outside reliable envelope delivery.

Exit requires interruption and restart recovery, corrupt and duplicate chunk rejection, final integrity verification, bounded storage, cancellation cleanup, route-handoff continuation, and continued Control progress under transfer load.

## Milestone 10: Host API, storage, and lifecycle integration

**Status: Complete.** [Host API, Storage, and Lifecycle Design](Host-Integration-Design.md) defines application-facing services, repository authority, recovery ordering, lifecycle and background leases, lock handling, permission degradation, storage pressure, credential/revocation coordination, visible synchronization state, and privacy-safe diagnostic export. `BeakrNetHost` implements these platform-neutral boundaries, atomic monotonic checkpoints, ordered composite recovery, trust maintenance before route activation, and bounded canonical diagnostics. UI and Apple lifecycle adapters remain outside BeakrNetCore.

## Milestone 11: Production operations

**Status: In progress; design gate complete.** [Production Operations Design](Production-Operations-Design.md) defines secure key custody, workload authentication, layered admission controls, explicit revocation grace, privacy-safe audit and telemetry, integrity-committed backup/restore, rollout gates, and operational recovery drills. Development PSKs and filesystem authority keys are prohibited in this profile.

## Milestone 12: Additional transports and federation

**Status: Decision-gated.** WatchConnectivity, Bluetooth Low Energy, Wi-Fi Aware, specialized real-time media, and relay federation begin only for a concrete product scenario with measurable capability requirements. Each reuses the established node identity, authenticated session, envelope, acknowledgement, and route-handoff model.

Detailed dependencies, cross-cutting rules, deliverables, non-goals, and exit criteria for Milestones 6–12 are recorded in [Next Milestones](Next-Milestones.md).
