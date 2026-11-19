# BeakrNet Next Milestones

This roadmap begins after the completed transport and certificate-lifecycle foundation in Milestones 1–5. It distinguishes channel transport semantics, which already exist, from application protocols carried by those channels.

The package boundaries, dependency direction, regression-risk model, and required test layers for this work are defined in [Package Architecture and Testing](Package-Architecture-and-Testing.md).

## Node and routing design guidance

Future networking work must follow [First-Class Node and Mesh Design Goals](Node-Identity-Routing-and-Relay-Principles-2026-10-30.md): device-neutral node roles, separate identity and routes, explicit relay authorization, and independent authority hosting and network participation. Its proposed work sequence does not alter existing release acceptance or authorize additional transport implementation.

## Current baseline

BeakrNet already preserves explicit Control, Data, and Blackboard channel identity through encoding, queueing, relay and LAN delivery, route handoff, acknowledgement, duplicate suppression, expiry, and capability negotiation. The relay protects bounded Control capacity without starving application traffic. Authenticated sessions survive relay-to-LAN-to-relay changes without changing the envelope or repeating an accepted application operation.

The missing layer is typed meaning above the envelope:

- Control needs stable payload schemas and dispatch rules, including advisory authenticated peer-lifecycle transitions.
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

### Application state follow-up

Consolidate application connectivity decision-making after Release 1 stabilization. Transport lifecycle, authenticated-peer presence, network availability, and transition timing should feed one authoritative state reducer; sidebar, mailbox, member, status, and accessibility presentations should consume shared semantic labels and styles instead of maintaining parallel mappings.

### Network colour model — agreed and implemented November 9

User approved local operational health independent of peer presence: green for ready with zero peers or connected; blue for starting/reconnecting/discovery; red for unavailable, failed or Local Network permission denied. Saved networks not selected for messaging remain grey. Device counts continue to report peer presence separately. Authority hosting remains independently blue when running.

Mac and iPhone now share one colour mapping for network and status presentations. Network Status information and the no-peer explanation reflect this model. Existing state transitions and the 15-second initial discovery settling interval are unchanged. Both platform builds passed; live visual check pending.

### Authority-managed capability follow-up

After Release 1 stabilization, preserve the authority-owned policy, member capability, and negotiated-configuration boundaries described in [Authority-Managed Network Capabilities](Authority-Managed-Network-Capabilities.md). Custom compression and encryption providers remain deferred until their provider contracts, trust requirements, negotiation, compatibility testing, failure behavior, and administrative interface are explicitly designed.

### Mac Network Parameters window placement — completed November 9

User confirmed that View Parameters retains resized width and height across close/reopen and a full application restart, while opening beside the live right edge of Column 1 and top-aligned with the main window. Placement is constrained to the main display's usable bounds. This supersedes the earlier proposal for vertical centring and recalculating content-based height on each opening. Content remains scrollable as the device list grows. Settings retains its accepted resizing and relative-placement behavior.

### Post-R3 authority-state invalidation

Replace latency-sensitive authority polling with a lightweight authenticated invalidation event. When network-wide authority state changes, including a network rename, the authority sends connected members only the Network ID and newest signed-state generation. A member whose stored generation is older fetches and verifies the complete signed membership and revocation state before changing local application state. The notification is advisory and must never directly authorize or apply a name, role, service policy, membership, or revocation change.

Connection establishment must also exchange the current authority-state generation so an offline member refreshes immediately after reconnecting even when it missed the original notification. Periodic authority refresh remains a fallback safety net.

Required post-R3 test cases:

- A connected member learns of a network rename within seconds, fetches the newer signed generation, and updates the name without changing Network ID or active-network selection.
- An offline member misses the notification, reconnects, detects the generation mismatch during authenticated session establishment, and fetches the new name.
- A current or future-generation notification does not mutate application state until the corresponding signed authority snapshot is fetched and verified.
- Duplicate and stale notifications are idempotent and do not trigger repeated state changes or downgrade the stored generation.
- Malformed, unauthenticated, wrong-network, and unauthorized notifications are rejected without fetching or mutating state.
- A notification for one Network ID cannot refresh or rename another saved network.
- If notification delivery fails, startup, reconnection, manual Refresh, and periodic maintenance still converge on the current signed authority state.

## Milestone 6: Typed Control protocol

Define canonical, versioned payloads for the reserved Control namespace and a bounded codec/dispatcher. The initial implemented vocabulary should cover delivery acknowledgement, session liveness, queue pressure, synchronization hints, advisory peer lifecycle, and protocol errors. Capability and protocol negotiation remain authoritative in the authenticated LAN handshake; an envelope may report or request renegotiation but cannot override the signed transcript. Route availability and peer-lifecycle notices remain advisory and never authorize a route.

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

**Status: Complete.** Implemented by the platform-neutral `BeakrBlackboard` target with canonical synchronization, causal multi-value records, explicit conflicts, authorized durable repositories, generation-bound compaction, bounded subscriptions, and route-independent operation identity.

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

**Status: Complete.** Implemented by `BeakrNetTransfer` with canonical manifests and chunks, SHA-256 verification, bounded restart-safe staging, resume ranges, sender backpressure, cancellation, expiry, storage-pressure cleanup, verified publication, and route-handoff continuation.

Extend Data with bounded transfer manifests and chunks after ordinary messaging is stable. This milestone covers downloadable files and store-and-forward media, not live audio or video samples.

The milestone should provide content length and digest commitments, bounded chunks, resume offsets or chunk maps, staging storage, integrity verification before publication, cancellation, progress, backpressure, expiry, storage-pressure handling, and garbage collection. Control traffic must continue progressing during transfers.

Exit criteria include interruption and restart recovery, corrupt- and duplicate-chunk rejection, storage-limit enforcement, cancellation cleanup, final digest verification, and successful continuation across route handoff.

## Milestone 10: Host API, storage, and lifecycle integration

**Status: Complete.** Implemented by `BeakrNetHost` with application-facing service contracts, ordered durable recovery, lifecycle and permission degradation, storage-pressure admission, trust maintenance, synchronization state, atomic checkpoints, and privacy-safe diagnostics.

Expose supported application concepts rather than requiring applications to construct envelopes. Define repository protocols and host coordinators for messages, Blackboard state, transfer staging, pending work, credentials, and diagnostics. Add foreground/background lifecycle hooks, visible synchronization state, and privacy-safe diagnostic export.

Apple background execution and notifications are hints and bounded opportunities, not guaranteed delivery. APNs must trigger a refresh; it must not carry authoritative Blackboard state. UI work should consume these APIs but remain outside BeakrNetCore.

Exit criteria include process termination and relaunch, device lock, background-task expiration, denied Local Network and notification permissions, storage pressure, credential renewal during queued work, and deterministic recovery of user-visible state.

## Milestone 11: Production operations

**Status: Complete.** Implemented by `BeakrNetOperations` with validated deployment configuration, secure custody requirements, deterministic layered rate limits, bounded privacy-safe audit and telemetry, integrity-committed backup verification, atomic restore activation, custody readiness, and fail-safe rollout drills.

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


## Minor feature request: authority hosting status in Networks — November 7, 2026

Status: implemented November 9, 2026; Mac build passed. Visual confirmation pending; not an additional R1 acceptance requirement.

User reports that per-network Authority Hosting status is currently visible only in app Settings, not in View Parameters (Network) from the Networks list. Request: make stopped/running hosting visible through the existing authority icon on each network row, potentially using a slash for Stopped.

Proposed presentation for implementation review: normal authority icon for Running, slashed icon for Stopped, a distinct warning for Unavailable/failed, and a subtle progress indication for Starting. Provide a tooltip/accessibility label such as “Authority hosting: Stopped.” Also consider exposing the same read-only status in View Parameters (Network). Exact symbols and transitional presentation remain design details, not implemented behavior.

Scope the indicator to known local authority hosting on this Mac; a client cannot infer that an authority is stopped merely from failed reachability. Preserve the distinction between authority ownership, hosting availability and messaging connectivity. Keep messaging colour/presence independent; displaying status must not start/stop hosting or switch networks. This request does not add Host/Co-Host service roles or simultaneous messaging/presence networks.

November 9 implementation: the Networks settings sidebar now reuses the local authority hosting indicator already present on main network rows. Stopped adds a slash, running stays green, starting/stopping pulse orange, and failure uses a red warning. Missing observed state is Checking rather than Stopped. The independent Mac Network Parameters window includes the same read-only indicator with text. Tooltips and accessibility labels describe the local hosting state. No hosting actions or messaging semantics changed. My Mac BuildProject passed19:28:27; live visual confirmation remains pending. The preceding proposal records the original request.

November 9 visual follow-up: user confirmed the hosting state display and checkmark-before-authority order. The accepted authority symbol is now person.badge.key.fill (green running) and person.badge.key (muted outline stopped), replacing server.rack and the custom slash. Transitional and failure presentations retain their state semantics.


## Feature proposal: reset semantics and recovery — November 9, 2026

Status: recorded for design review; no reset behavior or implementation authorized. “Factory Reset” is a working name, not a defined operation. User identified its meaning and consequences as important enough to resolve before implementation.

Review alongside the broader application Settings and main-window information architecture. Decide whether distinct actions are needed for restoring application preferences, clearing remembered-device metadata, resetting a device's local Beakr state, and retiring an owned network/authority. These are candidate scopes, not approved reset modes.

The design must specify:

- Exactly which settings return to which defaults, and how defaults change across app versions.
- What happens to profiles, network memberships, device identities, keys/certificates, authority ownership and hosting, saved permissions, remembered devices, message history, attachments and pending work.
- Whether each effect is local only or requires a coordinated network action; deleting local credentials must not be described as revoking remote membership or removing remote copies.
- Backup/export, recoverability, re-enrollment and consequences for other devices when this device owns an authority.
- Preview and confirmation of the exact affected scope, plus behavior after cancellation, interruption or partial failure.
- Clear names and placement that distinguish preference restoration from destructive data or identity removal.

Do not infer a destructive factory-reset action from this feature entry. Resolve the product contract and review it before implementation; existing profiles, permissions and history remain untouched.

## Deferred review: network parameters, duplicate pages, and trust recovery — November 9, 2026

User explicitly deferred this work until tomorrow (November 10). Review Settings/Networks and independent View Parameters together before further implementation. They duplicate network/device/authority information but differ in hosting controls and local-device health presentation.

The R1-E8-Test message “saved trust information has expired” maps to LANHandshakeError.staleRevocationSnapshot, not necessarily device certificate expiry. The revocation snapshot freshness limit is 24 hours plus allowed clock skew. Current UI does not expose the specific snapshot generation/expiry timestamps. Show which information is stale, the issuing network authority, last update, expiry, and an appropriate direct recovery action. Distinguish starting local authority hosting from refreshing signed trust data; do not imply missing peers caused this failure. Recovery has not been live-confirmed in this sequence.

User accepts the network disclosure group's multi-row highlight as useful context for network, authority and devices. Do not narrow it as an unsolicited correction. Existing icon, colour and window behavior changes remain in place. No further parameters redesign or trust-recovery implementation authorized for tonight.

November 9 later clarification: user reconsidered the grouped network selection after seeing its active blue highlight. Network-only header selection is now implemented with separate disclosure control and child rows (Mac build passed21:27:29; visual check pending), superseding the earlier instruction to retain the grouped highlight. This does not reopen the deferred parameters/trust review.

## Settings consolidation — November 10, 2026

The user authorized the first UI migration, superseding the November 9 deferral of duplicate-page work. Implemented a two-column local Settings window: This Device, Networks, Services. Networks provides instance disclosures with shared parameters, devices, registration and hosting controls. Main-window View Parameters opens that same Settings destination; the independent Mac parameters page is removed. Services > Messaging uses the existing single selected messaging network. Device membership/identity stays within its network context.

Mac and iPhone builds pass; visual review and live menu-latency verification are pending. Preserve existing Settings window alignment and resizing. Review repeated View Parameters requests while Settings is already open, disclosure layout at narrow sizes, and all existing creation/join/hosting actions. The menu-time selection mutation has been removed as a suspected contributor to popup delay, not a measured fix.

Later steps: deeper-panel toolbar history; explicit Local/Remote target selection and capability-dependent remote controls; specific trust freshness/issuer/expiry and recovery presentation. Remote configuration and trust protocol changes are not implemented. Reset semantics remain a design proposal only.


## Automatic network credential recovery — November 17, 2026

User authorized the credential recovery core and UI changes, superseding the earlier deferred trust-recovery work. Selecting a messaging network now prepares its credentials and starts its locally owned authority when needed. Automatic retries respect a persisted explicit Stop Hosting; explicit messaging selection or Start Hosting can restart it. Selecting another network does not stop existing authorities. Member devices never start a local authority for a remotely owned network.

Credential recovery coalesces attempts, cancels/drains on profile changes and backgrounding, and retries transient authority unavailability with capped backoff (2–30 seconds), foreground and path recovery. Existing valid signed caches remain usable. Expired or revoked access and invalid signed records remain fail-closed; refresh does not grant permissions. Missing or expired transport certificates use the existing authenticated enrollment flow. Ordinary LAN restart failures retain their existing recovery behavior.

Mac and iPhone network panels now expose Refresh Network Credentials, specific preparation/waiting/authority-stopped/authority-failed/expired/revoked states, authority identity, access and device-certificate expiry, and signed revocation record update/freshness dates. Details currently describe the selected messaging network. Network header status takes precedence over generic Connection failed. Existing pencil edits, Network ID alignment and service selection presentation are preserved.

Validation: 12 package hosting/preferences tests passed. Isolated iOS simulator recovery/regression selections passed (11 executions plus the additional unavailable-endpoint test). The broader application suite initially had 86/89 passing; two relevant regressions were fixed and passed focused reruns. The unrelated inboxSaveFailureRetainsSenderQueue persistence assertion passed on targeted rerun without modification. Final iOS simulator build-for-testing, physical iPhone destination build (18:27:33), and My Mac build (18:27:49) passed. Scoped source diff whitespace check passed. Xcode destination restored to My Mac. No live app launch, live credential mutation, or physical-device recovery validation performed; live startup recovery and UI review remain pending.
