# BeakrNet Next Milestones

This roadmap begins after the completed transport and certificate-lifecycle foundation in Milestones 1–5. It distinguishes channel transport semantics, which already exist, from application protocols carried by those channels.

The package boundaries, dependency direction, regression-risk model, and required test layers for this work are defined in [Package Architecture and Testing](Package-Architecture-and-Testing.md).

## Current baseline

BeakrNet already preserves explicit Control, Data, and Blackboard channel identity through encoding, queueing, relay and LAN delivery, route handoff, acknowledgement, duplicate suppression, expiry, and capability negotiation. The relay protects bounded Control capacity without starving application traffic. Authenticated sessions survive relay-to-LAN-to-relay changes without changing the envelope or repeating an accepted application operation.

The missing layer is typed meaning above the envelope:

- Control needs stable payload schemas and dispatch rules.
- Data needs an application messaging contract, correlation, authorization, and durable node-side delivery state.
- Blackboard needs a replicated-state model, repository contract, synchronization protocol, and explicit conflict behavior.

The relay must continue treating application payloads as opaque. Transports carry envelopes and enforce negotiated limits; they do not decode application Data or Blackboard state.

## Ordering and dependencies

```text
Milestone 6: Typed Control protocol
        ↓
Milestone 7: Application Data protocol
        ↓
Milestone 8: Blackboard replication
        ↓
Milestone 9: Reliable large Data transfer
        ↓
Milestone 10: Host API, storage, and lifecycle integration
        ↓
Milestone 11: Production operations

Milestone 12: Additional transports and federation
    begins only after an explicit product decision
```

Control comes first because Data and Blackboard synchronization require common error, cancellation, pressure, and synchronization-hint behavior. Ordinary Data comes before large transfers so correlation, authorization, idempotency, and persistence are proven without chunking complexity. Blackboard follows the ordinary Data boundary but keeps its own semantic channel and repository.

## Cross-cutting rules

Every milestone must preserve these constraints:

- A channel is semantic identity, not a priority class or payload-size class.
- Compact and full representations remain the same logical operation when they represent the same content.
- Transports never reclassify a channel or interpret application payloads.
- Exactly-once network delivery is not promised. Stable IDs, acknowledgement, durable deduplication, and idempotent application operations provide effectively-once acceptance where required.
- Authorization is checked after authentication and before application dispatch or state mutation.
- Unknown payload versions fail explicitly and do not partially mutate state.
- Payload contents, credentials, keys, and private state stay out of diagnostics by default.
- Deterministic clocks, schedulers, repositories, and transports remain injectable for tests.
- New wire formats require canonical encodings, independent versioning, size bounds, and golden fixtures.

## Milestone 6: Typed Control protocol

Define canonical, versioned payloads for the reserved Control namespace and a bounded codec/dispatcher. The initial implemented vocabulary should cover delivery acknowledgement, session liveness, queue pressure, synchronization hints, and protocol errors. Capability and protocol negotiation remain authoritative in the authenticated LAN handshake; an envelope may report or request renegotiation but cannot override the signed transcript. Route availability remains advisory and never authorizes a route.

Implement this milestone as the platform-neutral `BeakrNetControl` target within the existing BeakrNet Swift package. `BeakrNetControl` depends only on `BeakrNetCore`; it is not a separate Xcode application project and must not import Apple UI, networking, or Keychain frameworks.

The milestone should provide:

- A versioned Control payload discriminator and canonical encoding.
- Typed payloads rather than payload-type strings with unvalidated bytes.
- Source, destination, session, and payload consistency validation.
- A dispatcher that separates protocol handling from application callbacks.
- Unknown-version and unsupported-message responses without reflection or amplification.
- Per-message authorization and rate/resource bounds.
- Acknowledgement integration without creating acknowledgement loops.

Exit criteria:

- Every reserved Control payload has a concrete schema or is explicitly reserved and rejected.
- Malformed, oversized, unauthorized, replayed, and unsupported Control payloads fail closed.
- Control traffic still cannot be durable or carry application state.
- Mixed Control/Data/Blackboard traffic preserves bounded fairness through relay and LAN handoff.

## Milestone 7: Application Data protocol

**Status: Complete.** Implemented by the platform-neutral `BeakrNetData` target with canonical typed messages, bounded dispatch, durable outgoing and incoming state, restart-safe idempotency results, explicit cancellation, and unchanged relay/LAN retry behavior.

Add the application-facing reliable message boundary above raw envelopes. Begin with bounded messages and request/response; do not add chunked files or live media yet.

The milestone should provide:

- Namespaced, versioned application operation identifiers.
- Typed message, request, response, cancellation, and application-error metadata.
- Correlation IDs distinct from Message ID and Session ID.
- Authorization before dispatch and idempotency keys for mutations.
- Durable outgoing node queues and durable incoming deduplication records across restart.
- Explicit deadlines, cancellation behavior, backpressure, and bounded response sizes.
- An application handler protocol that does not expose transport selection.

Exit criteria:

- A request can start on one authenticated route, retry unchanged on another, and produce one application mutation and one correlated response.
- Restart tests preserve pending work and incoming deduplication.
- Unknown operation versions and unauthorized operations produce bounded failures without invoking handlers.
- Control remains responsive under sustained Data load.

## Milestone 8: Blackboard replication

Define Blackboard as replicated application state rather than a differently prioritized Data message. Begin with a small, generic repository and synchronization laboratory before selecting product-specific schemas.

The design gate must settle:

- Space, record, replica, operation, and subscription identifiers.
- Snapshot and operation-journal canonical formats.
- Causal metadata and compaction boundaries.
- Per-space membership and read/write authorization.
- Conflict representation and resolution ownership.
- Retention, tombstones, attachment references, and storage limits.

Wall-clock last-write-wins must not become the implicit conflict policy. If the first model cannot merge concurrent edits safely, it must retain an explicit conflict for application resolution. Clock values may support diagnostics and retention, but must not silently determine authorship or causality.

The first implementation should support named spaces, deterministic snapshots, incremental synchronization from a known cursor or causal frontier, offline operations, duplicate operation rejection, explicit conflicts, subscriptions, and restart-safe repositories. Attachments remain references to Data transfers rather than Blackboard blobs.

Exit criteria:

- Two replicas can edit offline, reconnect in either message order, and converge or expose the same explicit conflict.
- Snapshot plus journal recovery produces the same canonical state as uninterrupted operation.
- Unauthorized space access, rollback, invalid causal metadata, and compaction-boundary mismatches fail closed.
- Synchronization survives relay/LAN handoff without changing operation identity.

## Milestone 9: Reliable large Data transfer

Extend Data with bounded transfer manifests and chunks after ordinary messaging is stable. This milestone covers downloadable files and store-and-forward media, not live audio or video samples.

The milestone should provide content length and digest commitments, bounded chunks, resume offsets or chunk maps, staging storage, integrity verification before publication, cancellation, progress, backpressure, expiry, storage-pressure handling, and garbage collection. Control traffic must continue progressing during transfers.

Exit criteria include interruption and restart recovery, corrupt- and duplicate-chunk rejection, storage-limit enforcement, cancellation cleanup, final digest verification, and successful continuation across route handoff.

## Milestone 10: Host API, storage, and lifecycle integration

Expose supported application concepts rather than requiring applications to construct envelopes. Define repository protocols and host coordinators for messages, Blackboard state, transfer staging, pending work, credentials, and diagnostics. Add foreground/background lifecycle hooks, visible synchronization state, and privacy-safe diagnostic export.

Apple background execution and notifications are hints and bounded opportunities, not guaranteed delivery. APNs must trigger a refresh; it must not carry authoritative Blackboard state. UI work should consume these APIs but remain outside BeakrNetCore.

Exit criteria include process termination and relaunch, device lock, background-task expiration, denied Local Network and notification permissions, storage pressure, credential renewal during queued work, and deterministic recovery of user-visible state.

## Milestone 11: Production operations

Turn the existing protocol boundaries into a deployable service profile. This includes authority-key custody, enrollment and revocation HTTP hosting, service authentication, rate limits, abuse controls, backups, audit retention, privacy-safe telemetry, operational dashboards, deployment configuration, and selection of the offline revocation grace window.

Development PSKs and filesystem authority keys are prohibited in the production profile. Deployment tests must cover key rotation and recovery drills, restore from backup, endpoint overload, clock disagreement, stale revocation state, partial rollout, and rollback without weakening trust rules.

## Milestone 12: Additional transports and federation

WatchConnectivity, Bluetooth Low Energy, Wi-Fi Aware, specialized real-time media, and relay federation remain independent decision-gated projects. Each must declare capabilities and carry the existing authenticated envelope/session model without inventing a parallel identity system.

A transport should be added only when a concrete product scenario requires it and the laboratory can measure reachability, payload size, background behavior, energy use, ordering, and handoff. Relay federation additionally requires loop prevention, metadata minimization, administrative trust, and store-and-forward ownership rules.

## Explicit non-goals for Milestones 6–8

- No general mesh or relay federation.
- No WatchConnectivity, Bluetooth Low Energy, or Wi-Fi Aware implementation.
- No live-media packet transport.
- No rule engine, MCP surface, Siri/App Intents layer, or public Internet API.
- No product-specific Blackboard schema or automatic conflict resolution without an approved policy.
- No weakening of authentication, revocation freshness, envelope bounds, or route eligibility to simplify application protocols.
