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
8. Relay scheduling with reserved Control capacity
9. Persistent queues
10. Bonjour/direct-LAN transport and route selection

Structured diagnostics should accompany these changes. Datastores, external APIs, rules, MCP, Siri, WatchConnectivity, and Bluetooth remain outside the first milestone.

## First coding task

Implement and test the version-2 envelope contract in `BeakrNetCore`.

Completed. The package test suite includes a stable JSON fixture for schema version 2, compatibility rejection tests, channel and policy validation tests, session-boundary validation, and transport-preservation coverage. `BeakrNetHandoffLab` carries mixed Control and Data envelopes across relay/local/relay handoff while preserving deduplication.

## Next milestone

Define relay scheduling with reserved Control capacity before implementation. The design should specify queue partitioning or reservation, fairness, admission behavior under pressure, and diagnostics while preserving the immutable channel contract. Persistent queues, new transports, storage, rules, and UI remain out of scope until separately planned.
