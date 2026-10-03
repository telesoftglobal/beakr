# BeakrNet Architecture

BeakrNet establishes authenticated logical sessions between nodes and carries messages over the best available transport.

The detailed separation between logical channels, delivery policy, representation profiles, constrained transports, and real-time media is recorded in [Channel Model](Channel-Model.md).

The wider product architecture—including storage, rules, external APIs, relay federation, observability, and AI integrations—is recorded in [Beakr System Architecture](Beakr-System-Architecture.md).

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

## Versioned channel contract

Envelope schema version 2 makes Control, Data, and Blackboard semantics explicit alongside representation and delivery policy. Sessions validate this contract before accepting incoming envelopes or adding outgoing envelopes to pending delivery. Transports preserve the metadata and do not reinterpret application meaning.

Schema version 1 is deliberately unsupported because it lacks channel metadata. This avoids silently assigning legacy payloads to an incorrect semantic channel.
