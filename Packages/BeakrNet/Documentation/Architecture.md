# BeakrNet Architecture

BeakrNet establishes authenticated logical sessions between nodes and carries messages over the best available transport.

The detailed separation between logical channels, delivery policy, representation profiles, constrained transports, and real-time media is recorded in [Channel Model](Channel-Model.md).

The wider product architecture—including storage, rules, external APIs, relay federation, observability, and AI integrations—is recorded in [Beakr System Architecture](Beakr-System-Architecture.md). The durable Context boundary, generic stores, and cross-device synchronization policy are defined in [Context, Storage, and Synchronization Design](Context-Storage-and-Synchronization-Design.md).

## Boundaries

BeakrNet owns:

- Stable node, session, message, and transport identities
- Transport-neutral envelopes
- Session lifecycle and transport rebinding
- Route capabilities and eventual route selection
- Authentication hooks and delivery semantics

BeakrNet does not own:

- XLS or application data
- Replication policy or conflict resolution
- Data-store authorization decisions
- Application user interfaces
- The meaning of application payloads

## Layering

```text
Application protocol
        │
Logical BeakrNet session
        │
Route selection
        │
Local | Relay | WatchConnectivity | Test transports
```

Discovery locates a candidate. Authentication establishes who it is. Authorization determines what it may do. A transport only carries envelopes.

## Initial proof

The first meaningful proof is two nodes retaining one logical session while moving between relayed and local transports without losing or duplicating messages.

`BeakrNetHandoffLab` provides the first deterministic version of this proof. It moves 100 messages over simulated relay, local, and relay routes. One acknowledgement is intentionally omitted so the message is retried and rejected as a duplicate at the receiver before being acknowledged.

## Relay client

`BeakrNetRelayTransport` is an actor-based reusable client transport. It owns TLS establishment, credential presentation, node challenge-response, frame reception, diagnostics, cancellation, and automatic reconnect with backoff. It does not silently replay application envelopes: unacknowledged-message policy remains part of the logical session and delivery layer.

## Certificate enrollment endpoint

`CertificateEnrollmentHTTPEndpoint` is a transport-neutral HTTPS handler with separate challenge and enrollment routes. `CertificateEnrollmentNetworkClient` performs the complete exchange and also serves as the renewal scheduler's requester. The package supplies a URLSession transport for Apple clients; production servers adapt their HTTP framework to the request/response value types rather than mixing enrollment messages into relay connections.

## Versioned channel contract

Envelope schema version 2 makes Control, Data, and Blackboard semantics explicit alongside representation and delivery policy. Sessions validate this contract before accepting incoming envelopes or adding outgoing envelopes to pending delivery. Transports preserve the metadata and do not reinterpret application meaning.

Schema version 1 is deliberately unsupported because it lacks channel metadata. This avoids silently assigning legacy payloads to an incorrect semantic channel.

## Relay scheduling

The relay queue reserves configurable per-node and global capacity for Control. Control receives preferential service on reconnect, with a bounded burst followed by one Data or Blackboard envelope when available. This protects acknowledgements, liveness, and queue-pressure messages without starving application traffic.

`PersistentRelayQueue` is the production relay's durable facade over the same bounded queue policy. It stores a versioned JSON snapshot using atomic file replacement after every completed enqueue and drain, restores entries with their original enqueue times, removes expired entries during recovery, and rewrites the cleaned snapshot. The file location defaults to `BeakrNetRelayQueue.json` in the server's working directory and can be set with `BEAKRNET_RELAY_QUEUE_FILE`.

Persistence covers queued relay envelopes and their scheduling metadata only. Aggregate diagnostic counters are process-local. Draining persists removal before network delivery, so a later milestone that requires relay-to-client at-least-once delivery must add an acknowledgement or leasing protocol; that transport-contract change is intentionally not part of Milestone 3.

## Milestone 4 design: authenticated direct LAN

Milestone 4 adds a direct-LAN route without changing logical-session identity or delivery ownership. It is intentionally split into discovery, secure connection establishment, authenticated capability negotiation, and route selection. A Bonjour result is never a route until all later stages succeed.

### Discovery

Apple-platform implementations should advertise and browse one versioned Bonjour service type with `NWListener` and `NWBrowser`. The listener uses a system-selected port. The TXT record is a small, cacheable hint containing only the discovery-format version, protocol major version, a Node ID hint, and a per-advertisement instance nonce. It must not contain credentials, public keys, scopes, addresses, session IDs, or authoritative capabilities.

Browser results retain the `NWEndpoint.service` value and interface set and pass that endpoint directly to `NWConnection`; BeakrNet does not resolve Bonjour names or cache IP addresses itself. Results are keyed by service endpoint plus advertisement nonce, removed when the browser removes them, and treated as untrusted. Local Network permission denial, browser failure, an empty result set, and an authenticated-peer failure are separate diagnostic conditions.

Every node may listen and advertise, but only the node with the lexicographically lower canonical Node ID initiates a connection for a discovered peer hint. The other node accepts. This deterministic rule prevents a pair of simultaneous connections. A hint collision or dishonest hint is harmless because the authenticated Node ID must match the expected peer before the connection becomes eligible; otherwise the connection is closed.

### Secure connection and peer authentication

The LAN connection must provide confidentiality, integrity, replay resistance, and mutual authentication. After the secure channel is established, both sides exchange authority-signed credentials and prove possession of their node private keys over one transcript containing:

- A LAN-handshake domain and protocol version
- Initiator and acceptor Node IDs and roles
- Both fresh 32-byte nonces
- The Bonjour advertisement nonce
- Both credential IDs
- The negotiated capability bytes

Each side verifies issuer, environment, validity window, revocation policy, Node-ID/public-key binding, required LAN service scope, and the peer signature before exposing a transport. A relay registration proof cannot be reused as a LAN proof because its domain and transcript are different. Authentication failure is terminal for that candidate and never falls through to an unauthenticated local route.

The current relay-lab TLS PSK is not suitable for LAN. It authenticates membership in one development environment rather than an individual peer, and distributing it to peers broadens compromise. The selected secure-channel profile is mutual TLS 1.3 with one P-256 certificate per node whose public key exactly matches the authority credential, followed by the domain-separated signed application handshake. Development uses a 30-day self-signed leaf from the node identity key; production enrollment issues a leaf for that same key. Network-framework trust evaluation is provisional until credential, certificate-key, certificate-fingerprint, scope, revocation, and proof checks finish, and a provisionally trusted connection is never route-eligible or allowed to carry application envelopes. See `Security-Model.md` for lifecycle and revocation policy.

### Capability negotiation

Capabilities are authoritative only when included in the signed handshake transcript. The initial LAN profile is ordered, bidirectional, foreground/immediate delivery for Control, Data, and Blackboard using full or compact representation. It has an explicit maximum envelope size and does not claim queued or background delivery. Bonjour TXT data may reject obviously incompatible protocol majors early, but it never authorizes a route.

Negotiation uses an intersection: protocol version, channels, representations, maximum envelope size, and delivery behaviors must satisfy the envelope being routed. Unknown required capability fields fail closed. Capability changes require a new authenticated connection and produce a new route generation.

### Deterministic route selection

Selection is per remote Node ID and considers only authenticated, ready routes whose negotiated peer is that Node ID and whose capabilities satisfy the envelope. The stable ordering is:

1. Direct LAN
2. Relay
3. Stable `TransportID` byte order as a final tie-breaker

There is no latency race, last-writer preference, or Bonjour-name preference. Relay remains connected while LAN is probed and authenticated. A preferred route is installed make-before-break; the old route remains eligible until the new route is ready. Promotion and demotion are serialized by a per-peer route coordinator and assigned a monotonically increasing generation so stale asynchronous callbacks cannot replace newer state.

### Delivery and handoff

The logical `BeakrNetSession` remains the only owner of pending deliveries, attempt counts, acknowledgement processing, and received-message deduplication. Route transports do not replay envelopes independently. Sending follows this sequence:

1. Add the immutable envelope to the session's pending set.
2. Snapshot the selected eligible route and generation.
3. Record an attempt and send the same envelope and Message ID.
4. Remove it only after the logical acknowledgement is accepted.

An acknowledgement arriving on any authenticated route completes the pending delivery. When a send fails, its outcome is treated as ambiguous: the coordinator marks that route unhealthy, reselects, and may resend the identical envelope over relay. The receiver's session-wide Message-ID set makes an after-write failure safe by rejecting the duplicate while still returning an acknowledgement. Route changes never create a new Session ID, renumber an envelope, mutate channel or policy, or clear pending/deduplication state.

Ephemeral messages are not retried after an ambiguous failure unless their protocol explicitly permits it. Expired messages are removed rather than rerouted. Queued and durable messages remain pending according to their existing policy. Relay persistence remains available throughout LAN use; selecting LAN does not drain, delete, or bypass already queued relay state. Ordering is per transport attempt, not globally strict across a handoff, so consumers use sequence numbers while delivery correctness relies on Message ID and acknowledgement.

### Failure handling and diagnostics

Discovery loss alone does not tear down a healthy LAN connection. Connection failure removes LAN eligibility immediately and selects relay if compatible. Authentication, scope, revocation, version, and capability failures are non-retryable until discovery metadata, credentials, revocation state, or configuration changes. Network unavailability and permission denial are retryable environmental failures with bounded backoff and jitter.

Structured events include discovery added/changed/removed, browser state, listener state, permission denied, connection state, authentication started/succeeded/rejected with a safe reason code, negotiated capability summary, candidate eligibility, route selected, handoff started/completed/aborted, send attempt/result, fallback selected/unavailable, and stale-generation callback ignored. Diagnostics must not contain credentials, proofs, private material, payload bytes, or full TXT records.

### Test seams

The design requires injected discovery, listener/connection factory, secure-channel authenticator, credential/revocation verifier, clock, nonce source, backoff scheduler, and route-event sink. Deterministic tests use scripted transports and discovery events; Network-framework integration tests are a smaller layer. Required scenarios include spoofed Bonjour hints, simultaneous discovery, invalid/expired/revoked/wrong-scope credentials, replayed proofs, capability mismatch, deterministic ties, make-before-break promotion, LAN loss, ambiguous sends followed by relay duplicate rejection, acknowledgement on a different route, expiry during handoff, stale callbacks, permission denial, and relay persistence while LAN is selected.

The Apple integration target is deliberately separate and opt-in. On macOS it exercises a real Bonjour listener/browser pair, TLS connection readiness, length-prefixed Network-framework I/O, the authenticated application handshake, envelope transfer, path-loss reporting, and cancellation. It uses development PSK TLS with deterministic certificate metadata supplied through the connection test seam. A signed app-hosted integration target remains necessary for production per-node `SecIdentity` provisioning, mutual-TLS trust evaluation, and iOS-family Local Network authorization.
