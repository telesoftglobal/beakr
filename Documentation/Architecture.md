# BeakrNet Architecture

BeakrNet establishes authenticated logical sessions between nodes and carries messages over the best available transport.

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
