# BeakrNet — Multi-Network Planning and Discussion

## October 30 design guidance

[First-Class Node and Mesh Design Goals](Node-Identity-Routing-and-Relay-Principles-2026-10-30.md) guides future multi-network, authority, and relay design. All devices remain first-class nodes; platform constraints belong in capability and transport adapters. The implementation-status descriptions below reflect the earlier planning baseline and must be checked against current code before implementation.

## Purpose

This document describes how profile-driven access to multiple Beakr networks affects BeakrNet's protocol, security, persistence, runtime, application, migration, and testing design.

Multi-network support is more than an application profile picker. The current BeakrNet source has no explicit `NetworkID` concept. Envelopes, credentials, queues, sessions, and routes are scoped by node and session identifiers, but not by a distinct Beakr trust domain. Genuine profile isolation therefore requires a protocol-level network boundary.

The first release may expose only one active network per installation, but the implementation should avoid making that limitation an architectural assumption.

## Required identifiers

Three identifiers serve different purposes and must remain distinct:

```text
Installation ID
└── Identifies this application installation locally
    Never used as network authorization

Profile ID
└── Identifies a locally saved network configuration
    Used for storage and user-interface selection

Network ID
└── Identifies a cryptographic Beakr trust domain
    Included in credentials and protocol validation
```

Each profile should also have its own Node ID:

```text
Profile
├── Local Profile ID
├── Network ID
├── Per-network Node ID
├── Node private key
├── Node credential
├── Trusted authority identity
├── Revocation state
└── Optional authority role and authority key
```

A single device may therefore have different Node IDs in different networks. This prevents unrelated networks from correlating the device through a shared protocol identity.

## Core protocol impact

### Credentials

`NodeCredentialClaims` currently includes an environment but no network identifier. An environment such as development or production is not a trust domain.

Credentials should be bound to:

```text
Network ID
Node ID
Node public key
Authority ID
Environment
Capabilities or scopes
Validity period
Credential ID
```

A credential issued for one network must fail validation in every other network, even if the same authority implementation or physical device is involved.

### Authenticated handshake

The authenticated handshake must prove that both endpoints are operating within the same Network ID. A session must not become authenticated unless:

```text
localProfile.networkID
    == localCredential.networkID
    == remoteCredential.networkID
    == negotiatedSession.networkID
```

Route availability, Bonjour discovery, and relay delivery cannot override this validation.

### Sessions

`Session` should carry its Network ID as immutable session context:

```swift
SessionContext {
    networkID
    localNodeID
    remoteNodeID
    sessionID
}
```

Every inbound and outbound envelope is validated against this context.

### Envelopes

Current envelopes contain session, source, and destination identifiers but no Network ID.

For strong isolation across relay queues, persistence, and handoff, envelopes should include a Network ID. This requires a deliberate envelope schema update and new canonical golden fixtures.

An old envelope must not be silently assigned to whichever profile is active. During this exploratory development stage, unscoped envelope versions are rejected. No backward-compatibility path is required.

## Queues and persistence

Current queues are primarily indexed by destination Node ID. Multi-network storage requires composite scoping:

```text
Network ID + destination Node ID
```

All stored state should be namespaced beneath the local Profile ID:

```text
Profiles/
└── <profile-id>/
    ├── membership
    ├── credentials
    ├── revocations
    ├── relay-queue
    ├── messages
    ├── blackboard
    ├── transfers
    └── diagnostics
```

Profile scoping affects:

- Relay queues.
- Duplicate-suppression state.
- Delivery acknowledgements.
- Persistent message state.
- Blackboard state.
- Transfer state.
- Revocation snapshots.
- Route caches.
- Session restoration.
- Operational audit and backup data.

Once multiple profiles are possible, no lookup should rely only on `NodeID`.

## Runtime design

Each profile should own an independent runtime context:

```text
Beakr application
└── Profile manager
    ├── Family profile runtime
    │   ├── Host coordinator
    │   ├── Sessions
    │   ├── Routes
    │   └── Stores
    │
    └── Work profile runtime
        ├── Host coordinator
        ├── Sessions
        ├── Routes
        └── Stores
```

Initially, the profile manager can permit only one configured profile. Designing it as a collection prevents global singleton state from blocking multi-network support later.

The current `NodeBootstrapModel` should evolve into:

- An installation-level profile manager.
- A separate bootstrap and enrollment coordinator for each profile.
- A per-profile runtime status model.

## Authority impact

Authority is scoped to a profile and network, not to the entire application installation.

A device can therefore hold different roles in different networks:

| Profile | Role |
| --- | --- |
| Family | Primary authority |
| Work | Ordinary member |
| Test | Recovery administrator |

Possessing the Family authority key grants no rights in Work or Test.

Keychain records must include profile or network scoping. A generic account name such as `node-credential` is insufficient for multiple profiles.

## Discovery impact

Bonjour and relay discovery need to identify candidate network context without granting trust.

An advertisement may expose a privacy-preserving network discriminator derived from the Network ID. The enrollment invitation carries the actual expected network and authority identity. A joining runtime accepts only candidates matching that invitation.

Discovery for one profile must never populate route state for another profile. Discovery and route availability remain advisory and cannot authorize cross-network communication.

## Application experience

### Active network status

`Active` describes an enabled network runtime, not merely a selected profile and not merely attachment to a particular Wi-Fi network. This meaning remains useful when Beakr permits more than one network to run concurrently.

The interface qualifies the active state with live route information. The Networks dialog and the first-page Network toolbar icon use the same color scheme.

| Color | Displayed state | Meaning and behavior |
| --- | --- | --- |
| Gray | **Inactive** | The network is saved, but its runtime is stopped. Beakr does not attempt discovery or delivery for it. |
| Orange | **Active — Reconnecting** | The local-network path or Beakr runtime is recovering. Discovery and authenticated routes are not yet ready. |
| Blue | **Active — Ready, no devices online** | The runtime is healthy and discovery is available, but no other authenticated devices are currently reachable. Messages to known members may still be queued. |
| Green | **Active — Connected** | At least one authenticated peer route is usable. The status may include the number of connected devices. |
| Red | **Active — Connection error** | Runtime startup, credentials, local-network permission, or trust recovery failed and requires recovery or user attention. |

Green must never mean only that the device is attached to Wi-Fi. Local-network attachment does not prove that another Beakr node is reachable or authenticated. Orange indicates recovery; blue distinguishes a healthy network with no currently reachable peers.

Known recipients come from signed membership and cached friendly names, independently of live route presence. An offline member remains selectable, is shown with a neutral presence indicator, and may receive a durably queued message. A green recipient indicator is reserved for a member with a currently authenticated route.

Network-path recovery should automatically restart discovery after Wi-Fi becomes available again. Pull to refresh remains a manual recovery action: it recreates the active network's LAN runtime, restarts Bonjour discovery, refreshes trust and membership, and then updates recipient availability.

### Presence update timing

The expected recovery sequence is orange while the LAN runtime restarts, blue as soon as the local runtime and discovery are ready, and green as soon as at least one peer completes authenticated admission. Green must be driven by peer admission and removal events rather than by a periodic user-interface poll. Consequently, the blue-to-green transition should follow the completed peer handshake immediately instead of waiting as long as the membership refresh interval.

The periodic 15-second reconciliation samples only local Bonjour names, cached friendly names, and authenticated-peer presence. It must not fetch signed membership or revocation state. Authority trust refresh occurs on startup, reconnection, manual Refresh, and the independent scheduled maintenance cadence. It is not the primary source of live route presence and should not delay the toolbar icon, Networks dialog, or recipient presence indicators.

The first release remains intentionally simple:

```text
No profile
├── Create Network
└── Join Network

One profile
├── Messages
├── Network status
└── Administration, when authorized
```

A later release may add profile selection:

```text
Current Network: Family ▾

Family
Work
Test
────────
Join Another Network
Create New Network
```

Creating or joining another network adds a profile; it never overwrites the active profile.

Notifications, badges, background work, and message composition must always preserve or display their originating profile where ambiguity is possible.

## Resource bounds and fairness

Concurrent profiles require limits at two levels:

- Per-profile limits prevent one network from consuming its own resources without bound.
- Per-installation limits prevent a large number of profiles from exhausting the device.

Scheduling should provide fairness across profiles and then preserve existing Control, Data, and Blackboard fairness within each profile:

```text
Installation scheduler
├── Family profile
│   └── Control/Data/Blackboard fairness
├── Work profile
│   └── Control/Data/Blackboard fairness
└── Test profile
    └── Control/Data/Blackboard fairness
```

Resource policies should bound active profiles, sessions, pending enrollment requests, queue bytes, background activity, and diagnostic retention.

## Cross-network isolation

Membership in multiple networks does not authorize a device to bridge them.

Data, routes, credentials, acknowledgements, control messages, Blackboard records, and transfers must never cross profile boundaries. Cross-network forwarding or relay behavior would require a separate explicit capability and policy approved by both trust domains. It is outside the initial enrollment and multi-profile scope.

## Compatibility policy during exploration

Existing exploratory credentials, envelopes, and saved development configuration do not require backward compatibility. Unscoped artifacts are rejected, and test or development installations must be reprovisioned with an explicit Network ID.

Credential and envelope schema changes still require new canonical fixtures and strict version rejection tests. No implicit Network ID, legacy profile, automatic conversion, or compatibility fallback may weaken the network boundary.

## Required tests

The package suite must prove that:

- A credential from Network A is rejected in Network B.
- A session cannot negotiate across networks.
- An envelope cannot cross profile boundaries.
- Identical Node IDs in separate networks do not collide.
- Queue draining is scoped by network and destination.
- Duplicate suppression is independent per profile.
- Revocation snapshots cannot cross networks.
- Authority rights do not carry between profiles.
- Relay and Bonjour results remain profile-scoped.
- Deleting one profile does not damage another.
- Fairness holds when several profiles are active.
- Unscoped and obsolete schema versions fail closed.
- Cross-network protocol failures produce privacy-safe diagnostics.

Pure protocol tests should remain deterministic and independent of Apple networking services. Apple integration coverage should be narrowly scoped to Keychain namespacing, profile restoration, Bonjour/relay adapter isolation, and application lifecycle behavior.

## Recommended implementation sequence

Although the first release exposes only one active network, implementation should introduce the multi-network foundations immediately:

1. Add `NetworkID` to `BeakrNetCore`.
2. Define a local `NetworkProfileID` outside the wire protocol.
3. Bind credentials to `NetworkID`.
4. Bind the authenticated handshake and session context to `NetworkID`.
5. Version envelopes to carry `NetworkID`.
6. Namespace persistence, queues, replay state, diagnostics, and revocations by profile and network.
7. Implement a profile manager that initially enforces a maximum of one profile.
8. Build first-network creation and enrollment on top of that model.
9. Add multiple-profile UI and concurrent runtimes in a later milestone.

This approach makes the one-profile limit a product policy rather than an architectural assumption. Removing the limit later exposes functionality built on already-isolated profile contexts instead of requiring a broad protocol migration.

## Initial scope boundary

The initial implementation does not include:

- Multiple concurrently active profiles in the application UI.
- Cross-network forwarding.
- Automatic trust between networks created by the same device.
- Shared credentials or Node IDs across networks.
- Watch-only multi-profile administration.
- Replicated or threshold authority across networks.
- Cloud-based profile synchronization.

The initial completion condition is one network profile operating through the new network-scoped protocol and persistence model, with deterministic proof that artifacts from every other Network ID are rejected.

## Immediate implementation decision

The existing implementation should be modified before `BeakrNetEnrollment` and its product user interface are built.

Adding enrollment immediately, without first introducing a network boundary into the existing protocol, would build enrollment on an assumption that Beakr has only one global trust domain. That would require substantial rework when multiple profiles are enabled.

### Phase 1: Network-scope the existing implementation

Introduce `NetworkID` throughout the existing foundation before implementing enrollment UI:

1. Add `NetworkID` to `BeakrNetCore`.
2. Add it to credential claims and credential verification.
3. Bind authenticated handshakes to it.
4. Add it to immutable session context.
5. Add it to envelopes through a new schema version.
6. Scope acknowledgements and duplicate suppression to it.
7. Scope relay queues, routes, handoff, and persistence to it.
8. Bind revocation snapshots and authority state to it.
9. Update canonical fixtures and existing tests.
10. Add explicit cross-network rejection tests.

The phase completion condition is:

> The complete existing package suite continues to pass, while every credential, session, envelope, queue, route, and revocation operation rejects artifacts belonging to another Network ID.

### Phase 2: Add the local profile abstraction

After the protocol recognizes independent networks, introduce a local `NetworkProfileID` and profile storage:

```text
NetworkProfile
├── Profile ID
├── Network ID
├── Node identity
├── Node credential
├── Authority trust
├── Revocation state
└── Optional authority state
```

The first-release profile manager should enforce a policy equivalent to:

```swift
maximumProfiles = 1
```

This preserves a simple product experience while ensuring the implementation is not built around global singleton state.

### Phase 3: Implement enrollment

Only after network and profile scoping are established should the package add:

```text
BeakrNetEnrollment
BeakrNetEnrollmentTests
```

Enrollment can then create or join a specific Network ID because credentials, handshakes, sessions, and persistent storage already enforce the network boundary.

### Phase 4: Integrate the Beakr application

Replace manual production provisioning with:

- **Create Network**
- **Join Network**
- **Approve Device**
- **Remove Device**
- **Recovery**

Retain the existing manual development configuration until the new workflow has equivalent test and operational coverage.

### Phase 5: Enable multiple profiles later

After single-network creation, enrollment, restoration, revocation, and recovery are reliable, product policy may permit several profiles. If the earlier phases are complete, enabling multiple profiles should not require another core protocol redesign.

### Immediate milestone definition

The immediate milestone should be named:

> **Network-Scoped Protocol and Persistence Foundation**

Its implementation order is:

```text
NetworkID type
    ↓
Credentials and authority
    ↓
Handshake and sessions
    ↓
Envelopes and acknowledgements
    ↓
Queues, routing, handoff, and persistence
    ↓
Host, relay, operations, and application bootstrap
    ↓
Enrollment
```

Updating the existing implementation and tests before adding the new product workflow makes network separation an enforced security property rather than a user-interface convention.

### Implementation status

The protocol and persistence foundation now implements the first two slices of this sequence:

- Credentials and authenticated LAN handshakes are bound to an explicit Network ID.
- Envelope schema version 3 requires a Network ID; unscoped schema versions are rejected.
- Logical sessions reject incoming envelopes and acknowledgements from another network before changing replay or pending-delivery state.
- Typed Control context repeats the Network ID and must match the enclosing envelope.
- Data, Blackboard, and Transfer envelope construction requires explicit network context.
- Route coordinators and relay queues are created for exactly one network and reject envelopes from another network.
- Persistent relay snapshots use format version 2, record their Network ID, and fail closed when opened for a different network.
- Host delivery context, command-line tools, relay operation, and the handoff laboratory propagate the selected Network ID.
- A bounded persistent profile registry stores canonical Red/Blue-style profile records, maintains one explicit active profile, and gives every profile a distinct UUID-derived storage root.
- Profile display names are labels only and never determine storage paths or protocol identity.
- Removing a profile from the registry does not delete its storage implicitly; recovery or destructive deletion must be a separate explicit operation.
- `ProfileRuntimeStorage` binds each runtime root to a canonical manifest containing its Profile ID, Network ID, and local Node ID before any repository is opened.
- Host checkpoints, Data state, Blackboard state, transfer staging, relay queues, revocation snapshots, and diagnostic export paths are derived from fixed locations beneath that bound root.
- A runtime root cannot be reopened for another profile, network, or local node, and a nonempty unbound directory is rejected instead of being silently adopted.
- `ActiveProfileRuntimeManager` resolves the registry's active profile and opens exactly one runtime; changing profiles requires the current runtime to be stopped first.
- Structured host diagnostics now persist canonically at the profile-owned diagnostics path with bounded event count and export size.
- The Beakr application bootstrap now resolves or creates its active profile before trust recovery and opens the corresponding profile-owned runtime.
- Revocation recovery in the application uses the active runtime's revocation path instead of an installation-global snapshot file.
- Background application transitions atomically checkpoint the active profile runtime.
- Runtime release is fail-closed: a clean stopped checkpoint and structured lifecycle diagnostics must persist before the active runtime reference is cleared.
- Production lifecycle adapters now expose the real profile-owned Data, Blackboard, and Transfer repositories to `BeakrNetHostCoordinator`.
- `ProfileHostServices` requires explicit trust-maintenance and route-policy implementations; it cannot construct a route-eligible host from repository access alone.
- `AuthenticatedTrustLifecycleService` requires explicit restore, credential-renewal, revocation-refresh, and checkpoint operations; none defaults to success.
- `ProfileRoutePolicyController` gates registered authenticated transport owners by global and LAN permission, but never authenticates, creates, or selects a route candidate.
- `AuthenticatedTransportRouteOwner` connects an already-authenticated LAN or relay transport to the existing peer route coordinator and session delivery driver.
- Enabling an owner creates a fresh authenticated candidate generation; disabling it withdraws that generation from both routing and delivery without silently closing the underlying connection.
- `ProfileConnectionRegistry` owns the profile's authenticated peer sessions and their LAN/relay transports.
- Admission requires a current verified revocation snapshot, installs it on the transport before route registration, and closes transports that cannot satisfy this prerequisite.
- Multiple transports for one peer share one logical session; removing the final transport removes the peer context after route withdrawal, revocation unregistration, and connection closure.
- `ProfileLANConnectionController` bridges discovered and accepted Bonjour connections into that registry only after the existing authenticated LAN handshake succeeds.
- LAN admission verifies the authenticated peer against the expected discovery identity, enforces duplicate and connection-count bounds, and closes or cancels connections on authentication or admission failure.
- Connection loss removes the corresponding transport through the registry so route availability and revocation distribution cannot retain a stale owner.
- `ProfileBonjourRuntimeService` owns browser and listener lifetime for one active profile and stops every admitted LAN connection when that runtime stops.
- Canonical discovery election remains in `BonjourDiscoveryCoordinator`; only a ready elected connection is forwarded for authenticated admission, and terminal connection state removes its registered transport.
- Accepted connections require an explicit trusted peer-context resolver. An unresolved inbound connection is cancelled before the handshake instead of treating its route or discovery metadata as authorization.
- `ProfileKeychainNamespace` derives a stable, disjoint Keychain service from the non-display Profile ID; Red and Blue therefore cannot select one another's signing key, TLS identity, or credential by name collision.
- Node signing-key and LAN TLS stores accept that namespace, and `KeychainNodeCredentialStore` validates both Network ID and local Node ID before saving or returning a credential.
- Stored credentials use canonical encoding and fail closed on malformed, noncanonical, cross-network, or cross-node material.
- The Beakr bootstrap now selects an existing profile, or reserves a new Profile ID during configuration, before loading or creating the node signing identity.
- Development authority metadata, the node credential, certificate enrollment, and the LAN TLS identity all use that same Profile ID namespace.
- Restoring an existing profile fails closed when its recovered signing identity's Node ID differs from the profile manifest; a device-global identity is no longer selected by the production bootstrap.
- `AppleProfileLANRuntimeFactory` now loads and cross-validates the active profile's signing identity, canonical node credential, LAN TLS identity, authority key, environment, network, and revocation snapshot before constructing LAN services.
- Production LAN construction creates separate TLS 1.3 initiator and acceptor parameters, a shared Bonjour endpoint registry, the browser, listener, connection factory, authenticated connection controller, and profile-owned Bonjour runtime.
- Invalid service types and advertisement nonces fail before Keychain or networking access; missing or mismatched identity, credential, certificate chain, or profile bindings leave the LAN runtime unavailable.
- Profile membership is represented by an independently versioned, authority-signed snapshot containing credential, certificate-public-key, Node ID, and stable Session ID bindings for exactly one Network ID.
- `ProfileMembershipDirectory` persists canonical membership beneath `trust/membership.json`, enforces byte and record bounds, rejects generation rollback or same-generation conflicts, and rejects duplicate nodes, credentials, certificate keys, or sessions.
- Accepted-peer resolution uses the TLS certificate public key only after the signed credential is revalidated for network, environment, expiry, and current revocation state; unknown or revoked keys resolve to no peer.
- The Beakr application now requires persisted, verified revocation and membership snapshots before constructing or starting its production LAN runtime.
- Outgoing discovery also requires the peer's signed membership Session ID; an advisory Node ID hint with no current membership record is cancelled rather than authenticated.
- Foreground activation starts the profile runtime after trust recovery, while background transition withdraws LAN and all route permission, stops Bonjour and admitted connections, and then checkpoints durable profile state.

For example, a session, route coordinator, and queue created for the Red profile cannot accept or deliver an otherwise valid Blue envelope even if its Node ID, Session ID, or Message ID happens to match.

Signed membership snapshots now have a bounded canonical HTTPS endpoint and client, monotonic generation enforcement, conditional ETag fetches, and a profile-host refresh controller with deterministic retry policy and privacy-safe diagnostics. Beakr refreshes membership during LAN startup. A verified persisted snapshot may sustain operation during a temporary authority outage; a first start without trusted membership remains fail-closed.

Active profiles now run continuous trust-state maintenance on a bounded fifteen-minute cadence. Each cycle refreshes and distributes revocations first, immediately applies the resulting revoked credential set to live membership resolution, and then refreshes signed membership. Revocation consumers close newly unauthorized authenticated transports, while cancelled background runtimes also cancel their maintenance task.

Authority membership publication now has one durable state owner. Successful certificate enrollment and renewal upsert the node record, preserve its stable Session ID, atomically persist a newly signed generation, and only then advance the served HTTPS snapshot. Explicit removal and complete-set replacement for approval or recovery use the same monotonic path. Invalid mutations leave both the durable and served generation unchanged.

`AuthorityTrustStateCoordinator` now composes the authority's membership and revocation endpoints over one bounded canonical trust ledger. Approval and enrollment upsert membership, while removal deletes membership and accumulates credential revocation; the combined state is validated and atomically persisted before either served endpoint advances. Failed operator mutations leave both generations unchanged. The existing credential tool exposes `trust-approve` and `trust-remove` commands, avoiding the older single-entry revocation overwrite behavior for these workflows.

`AuthorityControlPlaneRouter` now provides the platform-neutral listener boundary. It routes enrollment, membership GET, and revocation GET requests through layered global/source/identity/operation admission, enforces concurrency and header bounds, returns bounded retry guidance, and records structured audit outcomes without request bodies or free-form source data. Pure routing tests remain independent of Apple networking.

The `BeakrNetAuthorityServer` SwiftPM executable now supplies the macOS HTTPS adapter. It defaults to loopback-only, uses TLS 1.3 with an operator-provisioned PKCS#12 server identity, obtains the identity password from `BEAKRNET_AUTHORITY_TLS_PASSWORD`, and exposes LAN listening only through an explicit `--lan` option. Its bounded HTTP/1.1 codec rejects oversized or ambiguous framing, duplicate headers, transfer encoding, pipelining, and incomplete bodies; each connection carries one request and is then closed. The deterministic codec remains in `BeakrNetOperations`, while Network.framework and Security stay in the executable and security targets.

Signed-host validation now includes an opt-in, time-bounded loopback harness that generates disposable development certificates, launches the real authority executable, and exercises enrollment, membership, and revocation over TLS. The harness uses curl connection/operation deadlines and bounded graceful/forced process cleanup, so an unavailable listener cannot hang Xcode. Its deterministic construction and skipped-by-default behavior pass in the package suite; the coding-assistant sandbox cannot complete `SecPKCS12Import` because the host Security service returns `errSecInternalComponent` (`-26276`). The documented standalone-package Xcode run is therefore the required host validation environment.

Initial network creation now has an atomic package boundary. `NetworkBootstrap.create` generates a Network ID, Profile ID, node signing identity, authority signing identity, initial administrator credential, generation-one membership, empty revocation state, and a canonical manifest in a private sibling staging directory. On macOS it can also generate a P-256 certificate authority, DNS-bound HTTPS server certificate, and Apple-compatible PKCS#12 server identity through an explicitly selected OpenSSL executable. The TLS password is accepted in memory and passed to OpenSSL through its environment; it is not stored in the manifest or command arguments. Sensitive keys and the PKCS#12 file use owner-only permissions. The completed bundle is moved into place only after every artifact validates and persists; an existing destination is never replaced. `BeakrNetCredentialTool create-network` exposes this operation for development and controlled provisioning. Application Create Network UI remains separate follow-on work.

Authority packaging is now selected as an authoritative Mac node. `EmbeddedAuthorityNode` restores a network bundle, verifies its authority identity, composes enrollment/membership/revocation with the existing production admission and audit policy, imports the HTTPS identity, and owns a stoppable TLS listener. The macOS Beakr Create Network workflow binds bootstrap to the profile's Keychain node identity without exporting that node private key, stores the authority TLS password in device-only Keychain storage, pins the generated CA for all control-plane requests, activates the exact generated profile, and restores the embedded authority after relaunch. iPhone and Watch installations remain joining nodes rather than authority hosts. Optional relay configuration follows the same registry path. Simultaneous Red and Blue runtime operation remains disabled until lifecycle and resource scheduling are independently bounded per profile.

Persistent authority custody is now Keychain-backed as well. The authority signing private key, certificate-authority private key, and PKCS#12 password occupy separate profile-scoped, device-only Keychain records and are absent from the committed authority bundle. Because the current certificate issuer is OpenSSL-based, the CA private key is materialized only while the authority is running inside a randomly named `0700` temporary directory as a `0600` file; stop and failed-start paths remove that directory. A future Secure Enclave signer abstraction can eliminate that runtime materialization, but is not represented as complete by the current implementation.

## Invitation review, refresh interaction, and authority port decisions

### Implemented invitation-review sheet

Scan & Join and Paste & Join now:

- acquire and decode an invitation without immediately consuming it;
- present a review sheet before any network profile is changed;
- show the network name and Network ID;
- identify the issuing authority and its endpoint;
- show when the invitation was issued, received, expires, or expired;
- expose bounded technical details without making them the primary user experience;
- provide explicit **Accept** and **Reject** actions;
- disable acceptance when the invitation is already expired;
- show acceptance progress and the final success or failure result in the sheet;
- report a network-name collision instead of silently replacing or confusing an existing profile; and
- add the accepted network to the local network list only after authority contact and invitation validation succeed.

An invitation being single-use is an authority security property, not sufficient user-facing status by itself. A rejection should distinguish, where the authority can do so safely, among expiration, prior redemption, authority unavailability, invalid signature or contents, and a conflicting local profile. The review sheet should make the invitation lifetime and issuer understandable before the user accepts it.

The intended top-level choice is binary: **Scan & Join** or **Paste & Join**. A separate generic **Join Network** action is unnecessary because it presupposes hidden invitation state. Joining should begin from an invitation and proceed automatically after explicit acceptance, with a cancel path while work is in progress.

### Pull-to-refresh interaction

Pull-to-refresh is both a network recovery action and a status explanation. Its interaction should have distinct phases:

1. A small pull reveals the non-destructive network-status peek.
2. Continued pulling reaches a stable armed state with clear text indicating that release will refresh.
3. Releasing starts one refresh operation and gives visible confirmation that it began.
4. Additional rapid pulls are coalesced rather than starting competing reconnect sequences.
5. The operation ends with an explicit connected, no-peer, warning, failed, or timed-out result.

A timeout must not look identical to successful completion. While connection work is active, transitional icon states may pulse: grey while acquiring a usable local route and blue while the Beakr network is ready but still discovering or connecting to peers. Stable green means at least one other approved device is online. The status text, rather than animation alone, remains the authoritative explanation.

### Port 8443 and collision analysis

The current authority prototype uses TCP port `8443`. Peer messaging does not rely on that fixed port: its listener selects a port and advertises the resulting endpoint through Bonjour. Bonjour discovery itself uses the platform mDNS service.

Port `8443` is commonly used as an alternate HTTPS development port, but IANA registers TCP and UDP `8443` as `pcsync-https`; it is not assigned to Beakr. Two devices on the same LAN may listen on the same port because their IP addresses differ. A bind collision occurs when another process on the same device already owns the same transport, local address or overlapping interface, and port combination. Changing routers does not itself create that collision, although firewall, VPN, interface, and reachability changes can affect authority access.

The preferred production design is therefore:

1. Let an authority bind an available dynamic TCP port.
2. Advertise the exact endpoint through Bonjour.
3. Include the authority host and port in the signed invitation.
4. Persist the selected endpoint for the lifetime of the installed authority profile when practical.
5. If rebinding fails, select another port and republish discovery without changing the Network ID or cryptographic authority identity.

The port is transport metadata, not network identity. Users should identify a Beakr network by its display name plus immutable Network ID, while trust rests on its cryptographic authority. A port change must not create a new profile or silently change which Beakr network is active.

### Invitation confidentiality and recipient binding

The current invitation is authority-signed but not encrypted. Its authority key, certificate, network name, Network ID, and authority address are primarily public trust and discovery information. Its invitation ID is nevertheless a short-lived, single-use bearer capability: a party that copies the complete invitation could attempt to redeem it first with another device identity.

Encryption alone does not prevent that misuse if every holder can decrypt the same transferable invitation. Recipient binding is the more important security property:

1. The joining device creates its device identity first.
2. It supplies its public key or Node ID to the network manager through a bounded request.
3. The authority issues an invitation bound to that public key.
4. The signed invitation includes a recipient public-key hash.
5. Redemption succeeds only when the join request is signed by that exact device.
6. The invitation may additionally be encrypted to the device's public key for confidentiality.

These protections have distinct purposes:

```text
Signed
├── prevents modification
├── identifies the authority
└── binds every signed field

Recipient-bound
├── prevents another device redeeming a copied invitation
└── replaces first-holder-wins bearer behavior

Encrypted
├── hides network and authority metadata
└── protects QR, clipboard, and message contents from casual inspection
```

Beakr'Net should eventually support two explicit modes:

- **Quick Invitation:** authority-signed, single-use, short-lived bearer invitation intended for an in-person QR scan.
- **Private Invitation:** authority-signed, recipient-bound, and encrypted invitation intended for remote delivery and replacement-request approval.

The replacement-request workflow provides the natural foundation for a private invitation. The requesting device supplies its public identity, the authority-host administrator approves the request, and the authority returns an invitation encrypted and bound to that device.

Independent hygiene requirements remain important: never log complete invitation contents; avoid permanently storing raw invitations; offer to clear clipboard invitation data after acceptance; keep bearer invitations short-lived; do not include an expired invitation's complete payload in a human-readable replacement request; and continue using pinned TLS for redemption.

Implementation priority is therefore **recipient binding first, encryption alongside or immediately after it**. Encrypting the existing freely transferable bearer invitation would add complexity without preventing invitation theft.

This is a medium-to-large feature rather than a small encryption patch. A production implementation requires a recipient identity request, durable pending-request state at the authority, administrator approval and rejection UI, a recipient-bound invitation schema, binding enforcement during redemption, public-key encryption and decryption, secure approved-invitation delivery or polling, expiration and replay handling across restarts, compatibility policy for version-one invitations, and protocol, persistence, security, and UI tests. A reasonable implementation estimate is five to ten focused development days followed by real-device testing; supporting both quick and private invitation modes may extend that work toward two weeks.

Recipient-bound encryption should follow stabilization of profile and Network ID persistence, authority discovery and reconnection, invitation creation and redemption, foreground and background recovery, message delivery and persistence, and the pending replacement-request workflow. The design should remain documented now so those foundations do not preclude it.

Smaller invitation-hygiene changes should precede the larger protocol work: complete invitations must never be logged; raw invitation text should not be retained after a terminal result; a pasted invitation should be removed from the clipboard after successful acceptance when the clipboard still contains that exact value; bearer invitations should remain short-lived; and replacement requests must not disclose the complete expired invitation.

### Consumable replacement requests and QR approval

A human-only replacement request places too much responsibility on users who may not understand Network IDs, authorities, invitation expiry, or device identities. A replacement request should therefore be both human-readable and machine-consumable by another Beakr'Net instance.

The intended workflow is:

```text
iPhone-Dev
    ↓ creates signed invitation request
Signal / Mail / AirDrop / QR
    ↓
Mac Beakr'Net recognizes request
    ↓
“iPhone-Dev requests access to Green”
    ↓ administrator approves
Mac generates recipient-bound invitation
    ↓ displays QR code
iPhone scans QR
    ↓
Network joins automatically
```

The signed request contains no private key or other secret material. Its bounded schema should contain:

- format and schema version;
- request ID;
- requested Network ID;
- referenced expired invitation ID;
- requesting device friendly name;
- proposed Node ID;
- requesting public key;
- creation and expiration times; and
- a signature produced by the corresponding private key.

Before presenting approval, the managing Beakr'Net instance verifies that the format is supported, the Node ID derives from the supplied public key, the request signature is valid, the request is current and has not already been processed, the referenced network is hosted or manageable on that device, and the expired invitation was originally issued by that authority.

Approval creates a new invitation bound to the requesting public key. Presenting that invitation as a QR code gives the administrator a simple delivery path and prevents a different device from redeeming it. The request transport can remain flexible: a direct Beakr link, pasted encoded request, request QR code, or eventually a Beakr message should all decode to the same canonical signed request.

A shared representation may combine a human explanation with a machine-readable link:

```text
iPhone-Dev is requesting a new invitation to Beakr'Net – Green.

Open this request with Beakr:

beakr://invitation-request/<encoded-signed-request>
```

The requesting iPhone must create and retain its proposed profile identity before producing the request. The current join sequence creates a profile identity during redemption; it must be adjusted so the request-signing identity is the same identity later authorized by the recipient-bound invitation. This identity reservation is the essential first implementation slice.

This workflow is also the correct precursor to private encrypted invitations. Once the authority has the requesting device's public key, the approved response can be both recipient-bound and encrypted without redesigning the user workflow.

### Existing-network invitation classification and repair

Creating a network and joining a network are different intents. **Create Network** creates a new immutable Network ID and is normally an authority-host operation. An invitation normally grants or repairs access to an existing Network ID. Scanning an invitation must never create a second local profile for a Network ID already stored on the device.

Every invitation should be classified before redemption:

| Comparison | Meaning | Action |
|---|---|---|
| Same Network ID and same authority | Existing membership | Reconnect or repair in place |
| Same Network ID but different authority identity | Possible corruption or attack | Refuse and warn |
| Different Network ID but same display name | Separate network with a naming collision | Join with a distinguishing local name |
| Different Network ID and different name | New network for this device | Join normally |

When the matching profile has no authenticated peers, the invitation sheet should explain that the device is already on that Beakr'Net and offer **Repair Existing Network**, **Try Reconnecting**, and **Cancel**. Blue is not proof of corruption: it means the local profile is ready but has no authenticated peer connection. If an expected authority or peer remains unavailable, repair is an appropriate explicit recovery action.

Repair must preserve the existing profile, node identity, messages, friendly names, and settings. It verifies that the invitation's Network ID and authority key match the saved profile, redeems the invitation using the existing node identity, atomically replaces the credential and valid authority endpoint material, renews the LAN certificate as necessary, refreshes membership and revocation state, and restarts discovery. A same-Network-ID invitation signed by another authority must be rejected rather than treated as recovery.

The Networks page should describe invitations as a way to “join or repair access to an existing Beakr'Net.” iPhone copy must not claim that the device can host an authority unless iPhone authority hosting is actually implemented and supported.

### Future iPhone authority hosting policy

An iPhone will often be a person's first or only Beakr device, so iPhone authority hosting remains a worthwhile future capability. It should be an explicit advanced setting rather than part of the ordinary join flow. The default mode is **Off — Join Networks Only**; a future **On — Host on This iPhone** mode may be enabled only when the complete authority runtime is implemented and supported.

The setting must not become functional merely because the user interface exists. Enabling it eventually requires a tested iPhone authority runtime, clear Local Network and discovery permission handling, durable authority identity and recovery, understandable ownership and transfer controls, bounded battery and resource use, and honest behavior when iOS suspends the app or prevents inbound LAN service. The product must also explain that an iPhone authority may be temporarily unavailable while the app is suspended and provide an intentional path to move authority custody to another device.

Until those conditions are met, **Create Network** remains hidden on iPhone and Settings displays a disabled authority-hosting selector as a roadmap placeholder. The placeholder records the intended product model without persisting or honoring a preference that the runtime cannot yet satisfy.

### Discoverable repair and personal-network defaults

**Repair Network Access** should remain available from every saved network's parameter page, even when the local profile appears healthy. Repair requires a fresh invitation for that same immutable Network ID and trusted authority. It preserves the profile, messages, friendly names, settings, and device identity while renewing credentials, restarting the runtime, refreshing trust and membership, and repeating authenticated peer discovery. Making repair continuously available gives users a predictable recovery tool and lets testers exercise the complete path without manufacturing a corrupt profile. A repair invitation for another Network ID must be rejected before any profile changes occur.

A Beakr'Net should be treated as a private trust group, not as all Beakr devices sharing a home, company, router, or Wi-Fi network. A personal Beakr'Net connecting one person's own iPhone, Mac, and iPad is likely the natural default. People may explicitly create or join additional family, project, or organizational Beakr'Nets without sharing membership or data between them.

Every network's credentials, membership, discovered devices, recipients, cached friendly names, messages, invitations, and authority information remain scoped to its immutable Network ID. Display names are descriptive labels only and may collide. The physical LAN supplies transport but never implies Beakr'Net membership or trust. Until simultaneous multi-network operation is supported, the interface must clearly identify and switch the one active profile while retaining other profiles as inactive.
