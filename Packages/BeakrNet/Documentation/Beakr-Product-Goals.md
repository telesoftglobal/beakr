# Beakr Product Goals

_Working product direction, October 24, 2026._

## Product vision

Beakr is a personal information retrieval and analysis system. It gathers information, preserves it in user-controlled data stores, applies rules, and uses AI to help people understand and manage that information across their Apple devices without requiring a web application.

The project began with gathering Ripple network information for human and machine analysis. Relevant information already exists on the Internet, including Ripple software versions, performance information, and other operational material. Beakr should allow rules to retrieve selected pieces of this information and deliver useful results directly to devices such as an iPhone or Apple Watch. The person should receive the finding rather than needing to visit and operate a website.

Beakr remains exploratory and is driven by personal interests. Its novel direction is the integration of AI with user-controlled information, native Apple applications, rules, and local data stores.

## Emerging product model

- **Sources and gateways** gather information, initially including Ripple network information.
- **Data stores** preserve personal information under the user's control.
- **Rules** determine what is collected, transformed, retained, routed, or surfaced.
- **AI analysis** retrieves, summarizes, correlates, and explains that information.
- **BeakrNet** connects the person's devices and controls trusted membership.
- **Contexts and mailboxes** provide organization, history, and movement of information.
- **Native Apple interfaces** replace the usual browser-based administration console.

Most sophisticated information systems eventually direct the person to a website exposing the vendor's administrative model. Beakr should instead make configuration, authority, retrieval, and analysis feel like ordinary personal-device activities.

Networks are part of Beakr's trusted information fabric, not its primary subject. Once stable, network machinery need not remain prominent on the app root page. The person's information, rules, gateways, analyses, and data stores should become the principal objects.

“Personal Information Retrieval and Analysis system” is an appropriate working description without prematurely defining Beakr as a VPN, messaging client, database, or AI assistant.

## Exploratory narrow-band mesh direction

Another area of interest is genuine mesh networking over very slow, narrow-bandwidth radio systems. Material published by the YouTube account DataSlayer may provide useful examples. How this work should relate to Beakr or Apple devices has not yet been determined.

The unifying goal is broader than networking:

> Collect useful information wherever it exists, move it through constrained or intermittent paths, preserve it locally, and present only the relevant result on the person's Apple devices.

A narrow-band radio mesh introduces constraints that differ substantially from BeakrNet's current responsive LAN operation:

- connections may be intermittent;
- messages must be very small;
- delivery may take minutes or hours;
- nodes may need to store and forward data;
- duplicate delivery may be normal;
- acknowledgement and retry must be economical;
- priority, expiry, and compression become important; and
- rich synchronization may be impossible.

This resembles delay-tolerant messaging more than conventional LAN connectivity.

## Possible architectural relationship

The likely connection to Apple devices is a gateway: a Mac, an iPhone accessory, a Raspberry Pi, or dedicated radio hardware that participates in the radio mesh and translates selected radio messages into Beakr information objects. Beakr rules could then determine what deserves delivery to an iPhone or Apple Watch.

```text
Information sources
        ↓
Rules and analysis
        ↓
Beakr information objects
        ↓
Delivery channels
   ├── BeakrNet/LAN
   ├── Apple device synchronization
   └── Narrow-band radio gateway
```

This suggests the following long-term separation of responsibilities:

- **BeakrNet** manages trusted Apple-device membership and normal local transport.
- **Channels** describe ways information can arrive or leave.
- **Gateways** adapt external systems, including Ripple and radio meshes.
- **Rules** decide what crosses those boundaries.
- **Data stores** retain the complete material.
- **AI** turns retained material into compact, useful observations.

Radio-specific behavior is not part of Release 1. Existing concepts such as gateways, channels, queued delivery, contexts, and rules should nevertheless avoid assuming continuous, high-bandwidth connectivity. This preserves a natural place for constrained transports later without forcing BeakrNet itself to become a radio-mesh protocol.

The DataSlayer material may later serve as a design case study: select one realistic narrow-band workflow and test whether Beakr's information, queueing, priority, and gateway models can represent it cleanly.

## Architectural guardrails from constrained networking

Radio does not need implementation now, but it is a useful architectural pressure test. Current models should avoid assumptions that would later be expensive to remove:

- a device is continuously reachable;
- delivery is immediate or ordered;
- every participant has equal bandwidth;
- messages can be arbitrarily large;
- acknowledgements are inexpensive;
- one transport determines identity or authority;
- network membership automatically grants access to all information; or
- transport encryption alone determines data permissions.

The important separation is:

> Network membership establishes who may participate; data permissions establish what each participant may receive, retain, transform, or forward.

That distinction matters within today's Mac and iPhone networks and becomes essential with gateways or radio nodes. A future radio gateway might be trusted to forward a small alert without being permitted to access the underlying datastore or complete analysis.

Radio remains out of scope, while continuing to influence durable boundaries among:

- identity and network membership;
- roles and authority;
- datastore permissions;
- object-level access;
- gateway capabilities;
- message priority and expiry;
- transport-independent object identity; and
- delivery acknowledgement versus information processing.

Keeping these boundaries explicit should allow BeakrNet to serve today's Apple devices without closing off constrained transports later.

## Future direction: dynamic information connections between peers

_Recorded November 9, 2026, following discussion. Product direction only; no implementation or live testing authorized._

A peer subscription could deliver changing information over time: “tell me whenever readiness changes” or “send this permitted measurement periodically.” It could carry restricted query results, selected events or continuous samples. The current Shared Status service performs one request → one snapshot; it does not implement subscriptions or streaming.

A restricted query could be evaluated on the responding device and return only its permitted answer, leaving underlying records local. A subscription could deliver changes to that answer. The answer itself still reveals information and requires authorization; this is not a claim of cryptographic zero knowledge.

This would be an application-level relationship that could reuse existing authenticated transport, without necessarily requiring a separate socket or a new transport protocol. Existing Blackboard replication should be assessed for reuse when the purpose is keeping shared state synchronized.

Keep three responsibilities distinct:

- **Saved permission:** which specific operations and information a peer may subscribe to. Permission for one query does not automatically permit status snapshots, underlying records or arbitrary queries.
- **Active subscription:** what the peer is currently receiving, subject to current authentication, membership and service authorization.
- **Delivery rules:** frequency, buffering, expiry and behavior after disconnection.

Withdrawal must stop future disclosure; information already delivered cannot be recalled. Reconnection requires fresh authorization checks and explicit rules for resuming, sending the latest value or replaying missed events. Slow receivers require bounded buffering and a defined policy for reducing, dropping or pausing updates.

This direction fits Beakr's separation of trusted membership from information permissions and its support for intermittent connectivity. It is a candidate for a future bounded service, not a requirement to expand the current Shared Status permission-lifetime work. It does not authorize background networking, automatic grants, general Actor delegation, AI interpretation or simultaneous multi-network participation.

## Permission lifetime as a foundation for future services

_Recorded November 9, 2026, from the subsequent design discussion. These are recommendations and compatibility goals, not implemented behavior or approval to begin implementation._

### Proposed next bounded change

Separate saved sharing intent from transient runtime capabilities for the existing read-only Shared Status service. Preserve explicit sharing across ordinary disconnects, backgrounding and reconnection, while checking current authentication, membership and permission before every disclosure. Allow withdrawal while the peer is offline.

The recommended credential policy preserves sharing through certificate renewal using the same credential and node key, but requires a new grant after credential replacement or re-enrollment. Storage failures must fail closed. The proposed recovery guard would preserve sharing through clean restarts but require reconfirmation after an unclean shutdown; this tradeoff still needs agreement before coding.

After the policy is settled and implementation is authorized, the bounded phase would cover the profile-scoped permission store, runtime/UI integration, focused fixture tests and builds. Live Shortcuts testing remains a separate subsequent phase. The detailed parked case is in [Shared Status Shortcuts](Shared-Status-Shortcuts-2026-11-08.md#parked-connection-scoped-permission-conflicts-with-shortcuts).

### State-machine compatibility

Saved intent and runtime availability should be separate state dimensions. A small state machine can govern Shared Status permission lifetime using the existing lifecycle owners; a broader application state-machine refactor is not a prerequisite.

| Event | Permission state | Runtime behavior |
| --- | --- | --- |
| Enable successfully saved | Allowed | May serve after current authorization checks |
| Peer disconnects | Allowed | Invalidate capability and cancel pending work |
| Peer reconnects | Allowed | Revalidate before creating a fresh capability |
| User withdraws | Off in memory; persistence pending | Block disclosure immediately |
| Withdrawal save fails | Recovery required | Remain blocked; do not silently restore permission |
| Verified revocation | Invalidated; durable reconciliation required | Block and require a new explicit grant |

The coordinator serializes events, performs persistence effects and feeds success or failure back into the state machine. Revision checks prevent late saves, reconnects or sampling completions from restoring withdrawn access. Immediate blocking and durable completion are distinct; recovery behavior must account for interrupted or failed writes.

### Real-time performance monitoring compatibility

The same separation can support a future monitoring service:

- **Saved permission:** which measurements a peer may receive.
- **Active monitoring:** whether an authorized subscription is currently running.
- **Availability:** whether the peer and its measurements are currently reachable and fresh.

Disconnection stops delivery without erasing permission. Reconnection revalidates access, and withdrawal stops further disclosure. Missing or stale measurements must remain distinguishable from zero.

Monitoring additionally needs defined sampling rates, timestamps, bounded buffering, slow-receiver handling and limits on monitoring overhead. These are future service requirements. The proposed permission-lifetime change does not itself implement streaming or provide real-time timing guarantees.

### Remote configuration compatibility

For convenience, a person may want to configure an Apple Watch or iPad from a Mac. This fits the same separation of saved permission, authenticated identity and current availability.

The target device remains authoritative: the Mac requests a specific configuration change, and the target validates permission, applies it and reports the result. Network membership or permission to read status does not automatically authorize configuration changes.

Mutating configuration operations additionally require:

- Permission for specific settings or operations.
- Validation and an expected configuration revision to prevent overwriting newer changes.
- Safe retries that cannot apply a change twice.
- A clear distinction between request acceptance and successful application of the setting.
- Local confirmation for sensitive changes where appropriate.

A state machine can represent these steps, disconnection and uncertain outcomes. Apple Watch connectivity and execution limits require their own transport and lifecycle design. Remote configuration remains a future goal; the current proposed increment stays restricted to read-only status permission lifetime.

### November 9 implementation progress

After the discussion above, the user authorized the bounded Shared Status permission-lifetime implementation, including the interrupted-session recovery tradeoff. It is now implemented and fixture-tested, with offline withdrawal, credential/authority pinning, and separate saved permission and runtime capability lifetimes. See [current contract and exact validation scope](Shared-Status-Shortcuts-2026-11-08.md#november-9-persistent-permission-lifetime-implemented). Authorized live Shortcuts success is now demonstrated within the bounded evidence recorded in that contract; restart/network-switch retention and offline enablement are user-confirmed. The closeout withdrawal/submission ordering concern was reproduced and corrected with an explicit serialized response commitment boundary; committed responses may remain in flight after withdrawal. See the current contract for evidence and acceptance recommendation. The earlier discussion records the decision sequence; monitoring, subscriptions and remote configuration remain future goals.


### November 9 live permission-lifetime result

The bounded Mac/physical-iPhone Shortcuts check is complete: default denial, explicit sharing, successful authorized snapshot after phone background/runtime stop/reconnect, then user-confirmed offline withdrawal followed by verified denial. This supersedes earlier pending/unproven live-success statements. See [the full sequence and evidence limits](Shared-Status-Shortcuts-2026-11-08.md#november-9--bounded-permission-lifetime-live-check-complete). Restart/crash recovery, save failures and identity changes retain their separate fixture-only evidence; no broader live certification or new feature scope is implied. R1 remains accepted.


### November 9 — foreground subscription design reviewed

The accepted permission-lifetime increment is complete. A [bounded foreground status subscription design](Shared-Status-Subscription-Design-2026-11-09.md) now proposes separate monitoring permission, explicit Start/Stop, a 30-second renewable lease, fixed two-second sampling, one unacknowledged sample and no automatic restart after disconnect. It reuses the existing snapshot, authentication and serialized sample-commitment boundary; it does not implement performance metrics or background networking. This is a documented proposal only. Implementation requires a separate phase.


### November 9 — bounded monitoring implemented

The subsequently authorized foreground status subscription is now implemented with separate monitoring permission, explicit Start/Stop, fixed cadence/lease/backpressure limits and runtime-scoped state. Nineteen monitoring fixture cases plus twelve relevant existing regression cases pass; Mac/iPhone builds pass. Live monitoring and visual UI acceptance remain pending. See [the implementation and exact evidence](Shared-Status-Subscription-Design-2026-11-09.md#november-9--foreground-subscription-implemented-1648-est). This implements periodic delivery of the existing restricted snapshot, not performance metrics, durable streaming history, background execution, remote configuration or arbitrary query proofs. Earlier proposal-only wording is historical.
