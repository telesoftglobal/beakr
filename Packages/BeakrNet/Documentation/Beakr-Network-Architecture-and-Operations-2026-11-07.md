# Beakr network architecture and operations

Architecture, permissions, nodes and message exchange · November 7, 2026

This document describes the implemented Beakr R1 application and the networking components it uses. R1 was accepted within its documented test scope and evidence limitations on November 7. This is an explanatory architecture overview, not a new security certification or expansion of R1 acceptance. Earlier design documents contain proposals and historical descriptions; where they differ, this overview uses the current source and final acceptance record.

## 1. What a Beakr network is

A Beakr network is an authenticated group of nodes identified by a stable **Network ID**. It is a logical trust and communication boundary, not the Wi-Fi network to which a device happens to be connected. Two devices on the same Wi-Fi are not automatically members of the same Beakr network, and discovering a device does not grant permission to communicate with it.

Each network has an authority that approves membership and publishes signed trust information. Each participating app stores a local network profile: the network identity, its own node identity within that network, trust configuration, and references to its local runtime and storage. A device can save several profiles without actively communicating on all of them.

R1 has three separate choices:

| Choice | Meaning | Effect on communication |
| --- | --- | --- |
| Inspect a network | View its parameters, saved members, device details or mailboxes. | Inspection does not select that network for messaging or start its authority. |
| Use a network for messaging | Give that network the app's active messaging and presence-observation runtime. | One network per app is selected at a time. |
| Host a network's authority | Run that locally owned network's authority service on the Mac. | Several authorities can run independently of the selected messaging network. |

For example, a Mac can host both XYZ and E8 authorities while using E8 for its own messages. An iPhone can remain on XYZ and obtain XYZ trust updates from that Mac. The Mac is then a service provider for XYZ, but it is not an active XYZ messaging peer. Hosting a network does not add an online messaging device to its count.

## 2. The principal components

Beakr separates administration and trust maintenance from peer message exchange. These paths cooperate, but have different responsibilities.

```text
                   AUTHORITY SERVICE ON MAC
              enrollment / membership / revocations
                signed endpoint information over LAN
                       ^                  ^
                       | HTTPS            | HTTPS
                       |                  |
                MEMBER NODE A      MEMBER NODE B
                 local profile      local profile
                 identity/key       identity/key
                 trust snapshots    trust snapshots
                 durable Outbox     durable Inbox
                       |                  |
                       +-- authenticated -+
                           peer channel
                          messages + Control
```

The authority service is the network's trust administrator. It is not a mandatory forwarding hop for ordinary R1 messages. Member A sends directly to member B through an eligible authenticated LAN connection; B sends acknowledgements back through that connection. The authority may run on A's device, B's device or another Mac, without changing the distinction between these roles.

The app owns presentation, selected profiles, mailbox views and lifecycle coordination. The BeakrNet package owns reusable networking behavior: identities and credentials, enrollment, trust verification, discovery, sessions, protocol envelopes, transport adapters and durable delivery state.

| Component | Main responsibility |
| --- | --- |
| Beakr app | Network selection, device/member presentation, composition, mailbox history and application lifecycle. |
| Profile runtime | Activate the chosen network's configuration, identity, trust state and storage services. |
| Authority hosting controller | Persist hosting intent and manage each owned authority independently. |
| Trust maintenance | Refresh signed revocations and membership, and make verified updates available to connection admission. |
| Discovery and connection management | Find candidate peers, establish secure sessions, track usable routes and recover connections. |
| Messaging and persistence | Admit durable outgoing envelopes, deliver incoming data, suppress duplicates and handle acknowledgements. |

BeakrNet also contains relay, transfer, Data and Blackboard foundations. Their existence in the package does not make a relay service, Internet-wide mesh, cross-network forwarding or every application protocol part of the accepted R1 app topology.

## 3. Devices, nodes and identities

A **device** is the Mac, iPhone or simulator running the app. A **node** is its authenticated participant identity within a Beakr network. In R1, one app can therefore have several saved network memberships with distinct Node IDs.

| Identifier or value | What it identifies | What it does not establish |
| --- | --- | --- |
| Network ID | The logical network and its isolation boundary. | A Wi-Fi name, host address or currently running server. |
| Local profile ID | This app's saved configuration for a network. | A globally shared device identifier. |
| Node ID | A cryptographic participant identity associated with a node key. | A user's name or a permanent IP address. |
| Credential ID | A particular signed authorization credential. | The device's current presence or reachability. |
| Session ID | The protocol context used for communication between eligible participants. | A general permission to act on every network. |
| Message ID | A particular protocol envelope, retained through retries. | Proof that a person read its contents. |
| Friendly Name | A human-readable label displayed for a node/device. | Identity, membership or authorization. |
| IP address and port | A current transport location. | Cryptographic identity or trust. |

Apple-platform node keys and TLS identities are held through profile-scoped Keychain storage. A Friendly Name edit does not replace the node key, Node ID or membership. Moving to a different address or discovering a new authority port likewise must not create a new member identity.

The local **This Device** view can list all saved memberships and their network-specific Node IDs. A remote device's details describe the membership known in the inspected network; they are not a global inventory of that device's other memberships.

## 4. Permissions and trust

Beakr applies several gates. They must all be understood separately: operating-system access, network membership, credential authorization, live connection authentication and authority administration.

### Operating-system permissions

Local Network access allows the app to discover and communicate with nearby services. Camera access supports scanning invitations. These permissions do not approve a Beakr membership or grant administrative rights. Denying Local Network access can prevent discovery or connection even when saved membership is valid.

### Network membership and credentials

Enrollment establishes the node as an approved member. An invitation supplies network/joining information; importing one is not equivalent to completing membership installation. The joining node participates in a proof-bearing request/approval flow. Approved credentials and membership information must be verified and durably installed before normal participation is available. Persisted enrollment checkpoints allow interrupted work to resume rather than manufacturing another identity.

The authority issues signed credentials and membership information. Verification binds the material to the expected network, issuer, environment, node and key, and checks its validity and revocation status. Service scopes constrain eligible uses; the implemented LAN path requires the appropriate LAN scope. Membership alone is not a grant of every possible application permission.

### Authority administration

Authority ownership and running status are separate. The Mac's hosting controller checks that the requested profile is locally owned before exposing its running authority handle or changing its hosting intent. Administrative actions must retain the intended network/profile binding, even if the UI selection changes.

A running authority is not automatically an active messaging member. Conversely, an ordinary messaging member cannot acquire authority ownership by selecting a network or discovering the authority's service.

R1 does **not** implement a general User/Actor delegation model, a comprehensive per-user permission editor, mandatory Actor audit journal, or configurable Host/Co-Host roles. Those proposed concepts must not be inferred from today's node membership and local authority ownership.

### Live peer authentication

Bonjour advertisements are untrusted discovery hints. A claimed name, Node ID or address in an advertisement is not accepted as proof of membership.

Before a connection can carry application messages, the implemented LAN path combines mutual TLS 1.3 with an application-level signed handshake. The checks include the expected authority and network, credential validity, revocation information, the node/public-key relationship, LAN scope, certificate/key binding, fresh nonces and proof of the relevant private key. The signed handshake binds both roles and connection information, including certificate fingerprints, to prevent a proof captured on another connection from being reused.

TLS readiness alone is insufficient. A connection becomes an eligible route only after the application admission checks succeed. Session establishment also checks the eligibility of both endpoints against the verified membership directory.

### Saved information is not live authorization

Signed snapshots permit bounded operation without a continuously reachable authority, subject to the configured freshness and credential-validity rules. They are not permanent permission to work offline. Invalid, stale, wrong-network, rolled-back or revoked trust information cannot be treated as fresh authorization simply because it is on disk.

The UI can retain historical members, names and last-seen data even when that information is no longer sufficient to authorize live communication. Displaying a saved row never bypasses the live trust checks.

## 5. How peers discover and connect

The selected messaging runtime starts a Bonjour browser and listener. Its network-scoped discovery finds candidates, then the connection manager decides which peer should initiate. For a pair, deterministic Node ID ordering avoids both sides independently creating redundant connections; the lower-ordered Node ID initiates. The authority-hosting Mac has no permanent special initiator role.

The normal sequence is:

1. Restore the selected profile, identity, certificate and verified saved trust information.
2. Attempt the required trust maintenance and establish local eligibility.
3. Start LAN discovery/listening when the local path and permissions allow it.
4. Resolve a discovered candidate and establish the secure transport.
5. Authenticate and authorize the peer; register only an eligible connection.
6. Update observed presence and retry eligible queued messages.

An unknown discovered peer can trigger a bounded fetch of newer signed membership information. It does not insert itself into the trusted member directory. Concurrent requests are coalesced and unsuccessful recovery attempts back off, limiting the authority traffic an untrusted discovery hint can provoke.

## 6. How a message moves between nodes

The user interface and the durable delivery protocol have different responsibilities. A visible sending row is not itself durable acceptance, and a successful network write is not delivery confirmation.

1. **Compose and validate.** The app checks the destination and text, creates correlation information and presents a provisional outgoing row.
2. **Bind the network context.** The runtime supplies the selected Network ID, local Node ID, eligible pair session and sequence number. The message request cannot substitute another network identity.
3. **Create the envelope.** The Data envelope contains the routing/session identifiers, message identity, payload type, creation time and delivery policy. A text message also carries correlation and idempotency information.
4. **Persist before dispatch.** The messaging service enqueues the envelope durably before attempting a route. Failed queue persistence is an admission failure; provisional queue admission is rolled back.
5. **Try an eligible route.** A registered authenticated peer driver sends the envelope. If the route is unavailable, the accepted envelope remains queued locally.
6. **Validate and save at the receiver.** Session and envelope checks precede the application sink. The inbox records supported incoming data durably and handles a repeated Message ID idempotently.
7. **Acknowledge accepted storage.** The receive path sends a delivery acknowledgement only after the incoming sink succeeds, including a duplicate already saved successfully. A failed save is not acknowledged as delivered.
8. **Complete the sender's queue entry.** The sender validates the acknowledgement, removes the pending envelope durably and updates delivery presentation when that removal succeeds.

```text
Sender                         Receiver
  |                               |
  | save envelope in Outbox       |
  |------ Data envelope --------->|
  |                               | validate; save once
  |<----- delivery acknowledgement|
  | remove pending envelope       |
  | update delivery state         |
```

If an acknowledgement is lost, the sender can retry the **same envelope**. The receiver recognizes the Message ID and can acknowledge the already stored result instead of creating another visible copy. If an earlier save failed, a duplicate must still revisit the persistence path before acknowledgement. Replay handling must not accidentally turn an unsaved message into an acknowledged one.

R1 retries pending work at runtime startup and periodically while the runtime runs; the current application retry loop waits approximately two seconds between attempts. This is a scheduling detail, not a two-second delivery guarantee. Connectivity, suspension, trust freshness, queue capacity and delivery expiry still constrain progress.

### What the status means

| State or event | Meaning |
| --- | --- |
| Queued | Durable local work exists and awaits an eligible delivery route. |
| Submitted/sent presentation | A send was attempted or the UI observed the recipient online; by itself it is not durable remote delivery proof. |
| Delivery acknowledged | The protocol's receiver-storage/acknowledgement path completed and the sender processed the acknowledgement. |
| Read receipt | A separate application-level fact; transport delivery does not prove human reading. |

The guarantee is durable retry with duplicate suppression within the implemented protocol and storage boundaries, not universal exactly-once execution of arbitrary remote actions. The local mailbox's presentation metadata is also distinct from the authoritative delivery queue; a metadata-save error is not evidence that the durable send was never accepted.

Switching networks does not rewrite a pending envelope's network or destination. Queues and history remain associated with their original network/context, and work must wait for an eligible runtime and route for that network. History can remain readable when the network is inactive.

## 7. The communications that maintain operation

Messages typed by users are only one category of traffic. Discovery, authority requests and authenticated Control exchanges keep the network usable.

| Communication | Purpose | Trust boundary |
| --- | --- | --- |
| Peer Bonjour advertisements/browsing | Find candidate messaging endpoints and observe changes. | Discovery is a hint; authentication follows. |
| Authority endpoint discovery | Find the current address/port for the expected network authority. | Signed endpoint binding plus HTTPS trust; a discovered address alone is insufficient. |
| Enrollment and certificate requests | Join, install approved credentials, or obtain replacement certificate material when required. | Proof-bearing requests and verified authority responses. |
| Revocation refresh | Learn which credentials must no longer be accepted. | Verify signed state before activating it. |
| Membership refresh | Obtain the signed member directory used for admission and member views. | Validate network, signature, generation and validity. |
| Peer Control messages | Carry delivery acknowledgements, lifecycle notices and network information. | Existing authenticated sessions and matching protocol context. |
| Data delivery/retry | Exchange user payloads and recover pending work. | Eligible routes, durable state and receiver validation. |

### Trust refresh order and persistence

The active profile's trust-maintenance controller refreshes **revocations first**. It updates the membership directory's revoked-credential set before refreshing membership. This prevents a new member view from briefly authorizing a credential that the latest revocation information has already disallowed.

Refresh happens during startup, through scheduled maintenance, through explicit user refresh and through bounded unknown-peer recovery. The next scheduled attempt comes from the refresh controllers' policies; it is not the same timer as message retransmission. Conditional HTTP responses can avoid downloading unchanged state.

New trust state is verified and persisted before becoming active. Membership generations reject rollback and conflicting content at the same generation. Revocation distribution updates registered authenticated transports so an installed revocation can remove affected routes. Invalid responses or storage failures do not justify weakening authentication.

### Dynamic authority endpoints

Each enabled local authority can bind its own port. Clients discover signed endpoint information bound to the expected network/authority, verify it and use the selected endpoint through the trusted HTTPS transport. The endpoint cache has validity and generation checks; it is a routing aid, not an alternative trust root.

A port change is therefore a location change, not a new authority or a reason to re-enroll members. R1 acceptance included automatic scheduled recovery to a changed authority port with membership preserved. That observation does not establish a universal recovery-time guarantee.

### Peer state, lifecycle and recovery

The runtime exchanges authenticated peer network information for details such as reported addresses. These reports are short-lived observations, not identity proof. On normal backgrounding or shutdown, a node attempts an ephemeral lifecycle notice before disabling routes. The notice is advisory: abrupt termination, power loss or immediate suspension can prevent its delivery.

Path loss and discovery changes still drive recovery when no lifecycle notice arrives. Losing the last peer does not require the app to tear down all discovery and wait for the authority to return; the connection manager can continue watching for peers and retrying. Foreground recovery restores eligible runtime operation when the app becomes active again.

Lifecycle generations and cancellation prevent stale asynchronous completions from restoring a stopped runtime or attaching old work to a newly selected profile. Authority hosting has a separate owner and persisted intent, so a messaging switch must not stop another enabled authority.

These mechanisms provide recovery while preserving authorization. They do not promise continued iPhone execution while suspended, authority availability while a Mac sleeps, or a background daemon after the Mac app quits.

## 8. Presence and visible network state

Presence is an observation made by this app instance for a particular network. It is not a global declaration about a device.

| Display | Interpretation |
| --- | --- |
| Blue selected network | Its messaging runtime is ready, with no authenticated remote peer currently connected. A device count can include This Device. |
| Green selected network | Authenticated peer connectivity is present. This does not mean every saved member is online. |
| Starting/reconnecting | Runtime or connection establishment is in progress. |
| Failed / needs attention | Setup, local access or trust/connection requirements are not currently satisfied; inspect the reported cause. |
| Inactive | This network is not the app's current messaging network. |
| UnObserved | This app instance is not currently observing that member's presence on that network. It does not mean globally offline. |
| Authority Running | The local authority service is running; its status is separate from messaging presence. |

Inactive networks can display authenticated saved membership snapshots. Historical names and last-seen values may remain. A missing remembered Friendly Name can fall back to a node-based label; it does not by itself mean the membership disappeared. The local device can show its known local IP even for an inactive network; remote inactive-member IPs remain unknown rather than being inferred from another network.

For the Mac/E8 and iPhone/XYZ example, the iPhone may still refresh XYZ trust from the Mac authority while the Mac lists its saved XYZ members as UnObserved. Those two facts are consistent: the authority service is active, while the Mac is observing messaging presence on E8.

## 9. Failure behavior and boundaries

| Condition | Expected behavior or limit |
| --- | --- |
| A peer goes away | Its route is removed or becomes unavailable; local durable messages can remain queued. Discovery/recovery continues where the app can run. |
| The authority is stopped | New enrollment and authority-dependent updates are unavailable. Existing peer communication depends on still-valid cached trust, not indefinite offline permission. |
| Saved trust expires | Live operations requiring fresh trust fail closed. Historical member rows may still be shown as presentation-only data. |
| The authority changes port | Authenticated endpoint discovery can locate the new endpoint without changing identities. |
| The app switches messaging networks | The old messaging runtime stops; original queues/history remain isolated. Independently enabled authorities remain owned by the hosting controller. |
| A receive-store write fails | No successful-storage acknowledgement is emitted for that attempt; retry can revisit the save. |
| The app restarts | Saved selection, identities, durable state and hosting intent are restored and revalidated. Missing keys must not silently become a replacement identity for an existing credential. |
| A network service cannot start | Report the affected service's failure without replacing its credentials or treating unrelated networks as failed. |

Stopping hosting, leaving a network inactive, removing a live membership and deleting local history are different operations. R1's accepted workflows preserve that separation; this document is not an instruction to revoke or delete anything.

## 10. Implementation references and acceptance scope

The following source locations support this explanation and are useful when tracing behavior:

| Area | Primary reference |
| --- | --- |
| App startup, profile selection and administration | [NodeBootstrapModel.swift](../../../Apps/Beakr/NodeBootstrapModel.swift) |
| App LAN wiring, refresh and retries | [ApplicationLANRuntimeManager.swift](../../../Apps/Beakr/ApplicationLANRuntimeManager.swift) |
| Message composition and durable inbox sink | [MessageComposerModel.swift](../../../Apps/Beakr/MessageComposerModel.swift) |
| Independent authority ownership and intent | [PersistedAuthorityHostingController.swift](../Sources/BeakrNetHost/PersistedAuthorityHostingController.swift) |
| Authority creation and profile-scoped keys | [AuthoritativeNetworkCreator.swift](../../../Apps/Beakr/AuthoritativeNetworkCreator.swift) |
| Signed member eligibility | [ProfileMembershipDirectory.swift](../Sources/BeakrNetHost/ProfileMembershipDirectory.swift) |
| Ordered trust maintenance | [ProfileTrustMaintenance.swift](../Sources/BeakrNetHost/ProfileTrustMaintenance.swift) |
| Discovered authority HTTPS requests | [DiscoveredAuthorityHTTPTransport.swift](../Sources/BeakrNetHost/DiscoveredAuthorityHTTPTransport.swift) |
| Durable send admission and stable retries | [PersistentHostMessagingService.swift](../Sources/BeakrNetHost/PersistentHostMessagingService.swift) |
| Authenticated receive and acknowledgement boundary | [HostServices.swift](../Sources/BeakrNetHost/HostServices.swift) |
| Peer drivers and Control exchange | [ProfileConnectionRegistry.swift](../Sources/BeakrNetHost/ProfileConnectionRegistry.swift) |
| TLS policy | [LANTLSConfiguration.swift](../Sources/BeakrNetSecurity/LANTLSConfiguration.swift) |

The [R1 signoff audit](R1-Signoff-Audit-2026-11-01.md) and [adverse-condition acceptance record](R1-Adverse-Conditions-Acceptance.md) define what was tested and accepted. Their limitations remain in force, including missing full live freshness-boundary traces, some fixture-only authorization/failure scenarios, incomplete resource-trend instrumentation and unavailable clean-Mac creation checks. An architecture description does not fill those evidence gaps.

Future simultaneous multi-network messaging/presence, Host/Co-Host roles, general User/Actor permissions, configurable cryptographic/compression providers and broader relay/mesh deployment require their own design and acceptance. They are not automatically enabled by the components described here.
