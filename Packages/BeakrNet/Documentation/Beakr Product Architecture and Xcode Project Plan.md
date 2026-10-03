# Beakr Product Architecture and Xcode Project Plan

This page records the Beakr and BeakrNet architecture discussion so it can be reused when development moves between the demo, production application, and future Xcode projects.

The main decision is to keep BeakrNet as the shared networking foundation, preserve BeakrNetDemo as a laboratory, and create Beakr as the actual Apple-platform product.

## Product direction

Beakr is Apple-centric initially:

- iPhone and iPad provide the primary personal experience.

- Every installation is an independently identified Beakr node.

- The Mac provides optional persistent LAN infrastructure, storage, diagnostics, and relay services.

- Mobile nodes must remain useful offline and synchronize when a route becomes available.

- The Mac relay is helpful but must not be a prerequisite for opening or using the mobile application.

## Network model

A node should select the best available route without changing the application protocol:

1. Direct connection on the same LAN

2. Local Mac relay

3. Remote Internet relay

4. Persistent offline queue until a route becomes available

The current implementation primarily provides authenticated relay transport. Direct LAN discovery, automatic route selection, offline queues, and Blackboard replication remain future work.

## Beakr channels

The product model requires three explicit logical channels:

| Channel | Responsibility | Suggested delivery policy |
| --- | --- | --- |
| Control | Discovery, presence, capabilities, commands, acknowledgements, and connection negotiation | High priority, small messages, short expiry |
| Data | Point-to-point application messages and transfers | Reliable delivery, acknowledgement, retry, and store-and-forward |
| Blackboard | Durable shared-state publication and synchronization | Versioned, subscribable, persistent, and conflict-aware |

The current relay does not yet implement these channel semantics. It routes generic envelopes by source and destination Node ID and treats payloads as opaque bytes with a payload-type string.

The channel should become explicit envelope metadata. The relay may apply delivery policy based on the channel while continuing to treat application payload contents as opaque.

## Current BeakrNet components

The current Swift package already contains:

- BeakrNetCore

- BeakrNetSecurity

- BeakrNetAuthority

- BeakrNetRelayTransport

- BeakrNetTestSupport

- BeakrNetRelayServer

- BeakrNetNodeCLI

- BeakrNetCredentialTool

- BeakrNetHandoffLab

The package supports iOS, macOS, and watchOS. It already establishes the foundation for transport-neutral envelopes, authenticated sessions, relay transport, credentials, tests, and simulated handoff.

## Intended repository and Xcode organization

```text
Beakr/
├── Beakr.xcworkspace
├── Packages/
│   └── BeakrNet/
│       ├── Package.swift
│       ├── Sources/
│       ├── Tests/
│       └── Documentation/
├── Apps/
│   ├── Beakr/
│   │   └── Beakr.xcodeproj
│   └── BeakrNetDemo/
│       └── BeakrNetDemo.xcodeproj
└── Services/
    └── BeakrRelay/
```

Roles:

- Beakr is the overall product and repository.

- BeakrNet is the reusable Swift networking package.

- Beakr.xcodeproj is the production multiplatform SwiftUI application.

- BeakrNetDemo remains a networking and diagnostics laboratory.

- BeakrRelay will eventually package the signed macOS relay service.

## Safe project migration

Use a two-step migration to avoid breaking the working demo.

### Step one

Within the current repository:

- Keep the BeakrNet package where it is.

- Keep BeakrNetDemo working.

- Create Beakr.xcworkspace.

- Add the current demo project and local BeakrNet package.

- Create Apps/Beakr/Beakr.xcodeproj as a multiplatform SwiftUI application.

- Add the local BeakrNet package to the production application.

### Step two

After the demo and production app both build:

- Rename the outer repository or container to Beakr.

- Move the package into Packages/BeakrNet.

- Move the demo into Apps/BeakrNetDemo.

- Repair local package references in the Xcode projects.

- Continue opening Beakr.xcworkspace rather than opening an individual project.

Do not rename BeakrNetDemo into Beakr. Preserve it as a test bench and build the production interface deliberately.

## Required Apple building blocks

The shared implementation should use:

- Swift Package Manager for protocol and node libraries

- SwiftUI for iPhone, iPad, and Mac interfaces

- Network.framework for listeners and connections

- Bonjour through Network.framework for LAN discovery

- CryptoKit for cryptographic operations

- Security and Keychain Services for identities and credentials

- SwiftData or SQLite behind repository interfaces for durable state

- BackgroundTasks for bounded mobile synchronization

- UserNotifications and eventually remote notification wake-up hints

- OSLog for privacy-aware diagnostics

- WatchConnectivity if Apple Watch becomes an active node or companion

An iPhone or iPad should not be treated as an always-running relay because iOS background execution is limited. Persistent relay duty belongs on macOS or a hosted service.

## Development stages

1. Formalize Control, Data, and Blackboard channel metadata and delivery rules.

2. Add persistent client and relay queues, recovery, deduplication, and diagnostics.

3. Add Bonjour discovery, authenticated direct LAN transport, route selection, and transport handoff.

4. Implement Blackboard storage, journals, subscriptions, snapshots, deltas, offline changes, and conflict handling.

5. Add hosted Internet relay, enrolment services, wake-up notifications, monitoring, and operational controls.

6. Harden security, migration, recovery, accessibility, testing, distribution, and observability.

## Immediate next step

Before reorganizing the filesystem extensively or implementing Bonjour, define the versioned channel and delivery contract in BeakrNetCore.

The first production Xcode action is to create Beakr.xcworkspace and a separate multiplatform Beakr application project while retaining BeakrNetDemo unchanged as the network laboratory.

## Exploratory Apple networking feature survey

Before committing Beakr to a particular protocol, the exploratory project should investigate the full Apple connectivity environment. The important question is not merely whether a ping arrives, but whether an authenticated Beakr node can discover, select, maintain, change, and recover a useful relationship with another node across Apple devices and changing network conditions.

### Node identity and trust

Every installation should have a stable cryptographic identity independent of its IP address, hostname, relay, or Apple device name.

Explore:

- Key generation and Keychain persistence

- Secure Enclave-backed keys where practical

- Stable Node IDs derived from public identity

- QR-code and nearby pairing confirmation

- Credential issuance, expiry, rotation, and revocation

- Device replacement and identity recovery

- Friendly peer names separate from authenticated identity

- Personal, family, team, and public trust domains

- Mutual, authority-issued, and combined trust models

An IP address is a route and must never become the node identity.

### Discovery

Beakr needs several discovery scopes because no single Apple technology works everywhere.

| Scope | Candidate technology | Purpose |
| --- | --- | --- |
| Same LAN | Bonjour with NWBrowser and NWListener | Find nodes and local relays |
| Nearby without an ordinary LAN | Wi-Fi Aware | Secure, high-throughput peer connections on supported devices |
| Nearby experimental | Multipeer Connectivity | Rapid peer-session experimentation |
| Physical proximity | Nearby Interaction | Distance and direction confirmation, not general data transport |
| Internet | Relay directory or known endpoints | Locate remote relays and nodes |
| Manual bootstrap | QR code, link, code, or NFC | Establish the first trust relationship |

Discovery should reveal candidates, not automatically trust them.

### Transport diversity

The application protocol should operate across interchangeable transports:

- TLS over TCP using Network.framework

- QUIC experimentation

- WebSocket where infrastructure compatibility matters

- Direct LAN connections

- Local Mac relay

- Hosted Internet relay

- Wi-Fi Aware

- Multipeer Connectivity adapter

- WatchConnectivity adapter

- In-memory and simulated transports

Core Bluetooth is worth exploring for discovery, pairing, and small Control messages, but not as the principal bulk Data transport. Nearby Interaction supplies proximity information; it does not replace the data connection.

### Route intelligence

A node may have several routes simultaneously. Route selection should consider:

- Direct versus relayed latency

- Available bandwidth

- Constrained and expensive paths

- Wi-Fi versus cellular

- Local-only versus Internet reachability

- Energy cost

- Relay health

- Security capabilities

- Channel requirements

- User preference

- Application lifecycle state

Important experiments include relay-to-direct handoff, direct-to-relay fallback, Wi-Fi-to-cellular transition, IPv4 and IPv6 changes, sleep and wake, suspension and relaunch, duplicate connections, and avoiding duplicate delivery during route changes.

The logical session should survive a transport change.

### Control, Data, and Blackboard channels

The exploratory project should determine which channel semantics are genuinely required.

#### Control

Possible features include presence, capability exchange, version negotiation, route offers, heartbeats, acknowledgements, flow control, subscriptions, and administrative commands. Control traffic should remain small, prioritized, bounded, and protected from application congestion.

#### Data

Possible features include point-to-point messages, request and response, streaming, attachments, acknowledgement, retry, expiry, progress, cancellation, idempotency, and backpressure. Large transfers must not prevent Control messages from progressing.

#### Blackboard

Possible features include named shared spaces, publish and subscribe, snapshots, operation journals, incremental synchronization, offline changes, causal metadata, conflict detection and resolution, permissions, attachments, history, retention, and compaction.

One important experiment is whether Blackboard operations should use the ordinary Data queues or a dedicated persistence service.

### Delivery semantics

Beakr should explicitly explore:

- Best effort

- At least once

- Effectively once through deduplication

- Ordering within a session

- Ordering within a channel

- Unordered transferable chunks

- Expiring messages

- Durable messages

- Replaceable state where only the newest value matters

Exactly-once delivery should not be promised at the network layer. A practical system combines stable message IDs, acknowledgement, retry, deduplication, and idempotent application operations.

### Offline-first operation

The mobile product needs durable outgoing queues, durable incoming deduplication, restart recovery, queue limits, expiry, attachment staging, retry scheduling, partial synchronization, visible pending state, conflict presentation, storage-pressure handling, and recovery when credentials change offline.

The interface should distinguish:

- Offline but usable

- Waiting to synchronize

- Connecting

- Online through relay

- Online directly

- Partially synchronized

- Blocked by authentication or incompatibility

### Apple lifecycle behavior

Test foreground and background transitions, suspension, process termination, relaunch, device locking, network changes, Low Power Mode, Low Data Mode, background-task expiration, disabled cellular access, denied Local Network permission, and denied notification permission.

Candidate Apple facilities include BGAppRefreshTask, BGProcessingTask, BGContinuedProcessingTask, background URLSession for appropriate transfers, and APNs background notifications as synchronization hints.

Push delivery is not guaranteed. APNs should prompt a node to check for work rather than carry authoritative Blackboard state.

### Apple multi-device continuity

Explore:

- Handoff with NSUserActivity

- WatchConnectivity

- ShareLink and share extensions

- App Intents and Shortcuts

- Universal Links for invitations

- App Clips for lightweight enrolment where appropriate

- SharePlay and GroupSessionMessenger for temporary collaboration

- Nearby Interaction for confirming physical presence

These should adapt into the Beakr node model instead of becoming separate application silos. WatchConnectivity, for example, can be represented as a specialized route between a watch node and its paired phone node.

### Wi-Fi Aware

Wi-Fi Aware deserves a dedicated experiment as a secure, high-throughput, low-latency peer-to-peer mechanism integrated with Network.framework.

Questions include supported devices and OS versions, required pairing interaction, operation without a shared Wi-Fi network, background behavior, energy cost, route handoff, and whether it can carry the normal authenticated Beakr envelope protocol unchanged.

It should remain an optional transport rather than an architectural requirement.

### Mac-specific opportunities

A Mac may provide independently selectable roles:

- LAN service directory

- Durable relay queues

- Blackboard replica

- Attachment cache

- Credential authority

- Backup and archival

- Network bridge

- Relay federation

- Diagnostics dashboard

- Automation endpoint

- Local AI or indexing services

- Policy enforcement

- Store-and-forward while mobile devices sleep

A user might enable Blackboard storage without enabling Internet relay access.

### Privacy and security

Explore Local Network privacy permission, Bonjour declarations, mutual authentication, end-to-end encryption above the relay, forward secrecy, metadata minimization, opaque payloads, per-channel authorization, blocking, revocation, replay protection, rate limits, resource bounds, private diagnostics, and local-data export and deletion.

The relay may need destination, channel, size, expiry, and routing metadata. Any additional visibility should be a deliberate choice.

### Diagnostics

The demo should expose node identity, discovered peers, available routes, selected route and reason, connection state, channel queue depths, acknowledgement state, retry counts, latency, transferred bytes, network interface, constrained or expensive path status, authentication failures, version mismatch, lifecycle events, and session handoffs.

It should support privacy-safe diagnostic export.

### Fault simulation

The laboratory should deliberately create packet loss, delay, reordering, duplicates, connection interruption, relay restart, node restart, corrupt frames, full queues, full storage, expired or revoked credentials, clock disagreement, simultaneous connections, conflicting Blackboard updates, old protocol versions, and hostile clients.

Deterministic clocks and simulated transports are essential.

### Recommended exploration labs

1. Identity Lab for creation, pairing, rotation, recovery, and revocation

2. Channel Lab for Control, Data, and Blackboard isolation, priority, and backpressure

3. LAN Lab for Bonjour discovery and direct Network.framework communication

4. Handoff Lab for relay and direct route changes without loss or duplication

5. Offline Lab for process termination, persistent queues, and replay

6. Wi-Fi Aware Lab for direct communication on supported hardware

7. Lifecycle Lab for backgrounding, suspension, wake-up, and recovery

8. Blackboard Lab for offline edits and later convergence

9. Continuity Lab for iPhone, iPad, Mac, and Watch role transitions

10. Adversity Lab for malformed traffic, overload, and credential failure

### Features not to make foundational too early

Be cautious about:

- Using Multipeer Connectivity as the only peer transport

- Using CloudKit as the Beakr protocol

- Assuming APNs provides guaranteed delivery

- Treating Bluetooth as a bulk transport

- Making an iPhone an always-running server

- Building a general mesh before proving direct and relay handoff

- Using Network Extension unless Beakr becomes a VPN, proxy, or filter

- Encoding application meanings into the relay

- Promising exactly-once delivery

- Depending on one Apple framework without a transport abstraction

### Recommended first experiment

Before freezing the envelope contract, evolve BeakrNetDemo into a Channel and Capability Lab. Two nodes should advertise their supported transports and protocol versions, exchange Control messages, send Data without starving Control, and persist one minimal Blackboard value.

This experiment will reveal what the eventual channel contract needs before it becomes difficult to change.
