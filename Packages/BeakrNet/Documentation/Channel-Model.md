# BeakrNet Channel Model

BeakrNet separates message meaning from delivery constraints and transport mechanics. This lets the same Control message travel over LAN, relay, WatchConnectivity, or Bluetooth Low Energy without becoming a different kind of message.

## Independent dimensions

A message has several orthogonal properties:

| Dimension | Examples |
| --- | --- |
| Logical channel | Control, Data, Blackboard |
| Delivery policy | Immediate, queued, durable, latest-value-wins, expiring |
| Representation profile | Full, compact, summary, chunked |
| Transport capability | Relay, LAN, WatchConnectivity, Bluetooth Low Energy |

A compact representation is not a separate logical channel. “Thin” describes a resource constraint, while Control, Data, and Blackboard describe message meaning and semantics.

Examples include:

- Watch presence update: Control, compact, latest-value-wins
- Watch command: Control, compact, immediate
- Small notification: Data, compact, queued
- Large attachment: Data, full or chunked, and potentially unavailable over Bluetooth Low Energy
- Watch dashboard state: Blackboard, compact projection, latest-value-wins

## Control plane across devices

Every Beakr node, including a watch, participates in a minimal logical Control plane. This does not require a permanently open physical connection. Background delivery, immediate reachability, and execution time remain subject to the operating system and transport.

The minimum Control vocabulary should cover:

- Node and protocol identity
- Authentication or pairing state
- Capability advertisement
- Reachability and route summaries
- Acknowledgements
- Version negotiation
- Queue pressure
- Wake and synchronization hints
- Compact administrative commands

The channel contract and reserved names exist today, but only delivery acknowledgement has a concrete typed payload. The next implementation milestone makes the remaining accepted Control messages canonical and typed. Capability and protocol negotiation remain authoritative in the authenticated handshake; Control envelopes may carry synchronization or renegotiation hints but cannot override negotiated security state. Route reports are advisory and cannot make a route eligible.

A constrained node may receive Control state eventually rather than continuously.

Relay queue capacity reflects this distinction. Data and Blackboard share an application partition whose occupancy cannot consume configured Control reservations. Control is scheduled first, but only for a bounded burst before an application envelope is selected, so protection of the control plane does not imply starvation of application traffic.

Those partitions and scheduling rules are invariant across relay restarts. Persisted entries retain their immutable channel and original enqueue time; recovery does not infer or reclassify channel semantics. Expired entries are discarded before they can be delivered.

## Constrained transports

WatchConnectivity and Bluetooth Low Energy are transports with distinct capabilities, not logical channels.

WatchConnectivity offers several delivery behaviors:

- Immediate communication when the counterpart is reachable
- Replaceable application context containing the newest state
- Queued background user-info transfers
- Background file transfers

Bluetooth Low Energy introduces small transfer units, chunking, flow control, variable latency, and battery constraints. These belong in transport capabilities and route selection.

Transport capabilities should eventually describe:

- Maximum practical envelope size
- Interactive and queued delivery support
- Background delivery support
- Ordering behavior
- Energy and monetary cost
- Chunking requirements
- Latest-value replacement support
- Supported representation profiles
- Supported logical channels

For Milestone 4, capability claims become authoritative only after authentication and transcript binding. Route selection intersects the envelope's channel, representation, payload size, and delivery behavior with the negotiated route capabilities. Direct LAN initially claims ordered foreground/immediate delivery only; the relay remains the queued fallback. A compact payload does not make an otherwise incompatible route eligible, and route selection never changes the envelope's channel, representation, or delivery policy.

Logical acknowledgements and deduplication are route-independent. An envelope attempted on LAN may be retried unchanged through relay after an ambiguous connection failure. Its original Message ID and Session ID allow the receiver to reject a duplicate and acknowledge it without repeating the application operation.

## Delivery and representation

A compact representation profile can coexist with explicit delivery policy:

```swift
enum RepresentationProfile: String, Codable, Sendable {
    case full
    case compact
}

struct DeliveryPolicy: Codable, Sendable {
    let priority: Priority
    let durability: Durability
    let expiry: Date?
    let replacementKey: String?
    let maximumPayloadBytes: Int?
}
```

The exact types remain subject to implementation design. The important decision is that representation, delivery, and transport constraints remain independent of logical channel.

### Version-2 contract

The implemented envelope schema version 2 encodes the logical channel, representation profile, and delivery policy explicitly. Version-1 envelopes are rejected because their missing metadata cannot be reconstructed without guessing application semantics.

Control currently has these enforceable constraints:

- Payload types belong to the reserved `beakrnet.*` namespace.
- Payload data is limited to 16 KiB.
- Delivery is ephemeral or queued for at most five minutes, never durable.
- Replacement keys are available only to queued delivery policies.

Data and Blackboard retain their channel identity when represented compactly or carried by a constrained transport. Channel fields are immutable after envelope construction; transports do not reclassify them.

A fourth channel should be introduced only when it represents independent application semantics. For example, a Signal or Telemetry channel could be justified for ephemeral, high-frequency, newest-value-wins information across multiple transports. Resource size alone is not sufficient reason for a new channel.

## Data transfer and media

The Data channel can carry:

- Media metadata and manifests
- Playback commands and synchronization
- Album art and thumbnails
- Downloadable songs and videos
- Progressive-download chunks
- Store-and-forward voice or video clips
- Stream negotiation, authentication, and capability exchange

Ordinary reliable BeakrNet envelopes should not carry individual live audio or video samples. Acknowledgement, retry, strict ordering, and deduplication can add latency and head-of-line blocking. For live media, an obsolete frame is often better discarded than retried.

The intended separation is:

```text
Control channel
  └─ Negotiate sessions, playback, clocks, and routes

Data channel
  ├─ Metadata, manifests, keys, and commands
  ├─ Downloadable media and reliable chunks
  └─ Stream setup and lifecycle

Media transport
  └─ Time-sensitive encoded audio and video packets
```

BeakrNet should authenticate participants, authorize content, establish the logical session, and select the route. A specialized media transport should carry high-rate, time-sensitive samples.

Reliable media transfer over Data will require:

- Chunking
- Backpressure
- Resume offsets
- Integrity hashes
- Cancellation
- Progress reporting
- Priority separation
- Bounded buffering

An initial Data delivery mode could distinguish ordinary messages, transfers, and stream control:

```swift
enum DataDeliveryMode {
    case message
    case transfer
    case streamControl
}
```

If real-time media becomes a core Beakr feature, a fourth semantic channel named Media or Realtime may be appropriate. Such a channel would be defined by bounded latency, pacing, clock synchronization, selective loss, and avoiding retries for obsolete frames—not merely by payload size.

## Application-semantics roadmap

Milestones 1–5 completed channel identity and the secure delivery substrate. Application semantics proceed in this order:

1. Typed Control payloads and protocol dispatch.
2. Bounded Data messaging and request/response with durable application delivery state.
3. Blackboard repositories, journals, snapshots, causal synchronization, and explicit conflict behavior.
4. Chunked and resumable large Data transfer.

Blackboard is not an alias for durable Data. It has distinct replication, authorization, subscription, compaction, and conflict semantics. Attachments may be transferred through Data and referenced from Blackboard state. See [Next Milestones](Next-Milestones.md) for scope and exit criteria.
