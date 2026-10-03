# Beakr System Architecture

The Beakr documentation distinguishes between two architectural scopes:

- **BeakrNet** is the transport and logical-session substrate.
- **Beakr** is the distributed application platform built above BeakrNet.

Logging, application datastores, rules, external APIs, cross-LAN federation, and AI integrations primarily concern the broader Beakr system. Some supporting capabilities still belong in BeakrNet.

| Topic | Architectural impact | Design area |
| --- | --- | --- |
| Logging | Cross-cutting observability, privacy, correlation IDs, retention, and export | Observability |
| Datastores | Durable queues, Blackboard state, configuration, credentials, and audit history | Storage |
| Rules | Automation and policy execution | Rules and policy |
| App and Internet APIs | Supported integration boundary above raw envelopes | APIs and gateways |
| Cross-LAN instances | Relay discovery, federation, routing, and loop prevention | Network topology |
| Rule location and execution | Authority, consistency, offline behavior, and security | Rules and policy |
| Rule structure and maintenance | Versioning, signing, migration, testing, and auditability | Rules and policy |
| AI, MCP, and Siri | Authorized adapters into the API, rule, and query layers | Integration architecture |

## Logging and observability

Logging should be structured and privacy-aware rather than scattered text output.

Events should carry identifiers where appropriate:

- Node ID
- Session ID
- Message ID
- Channel
- Route and transport
- Rule execution ID
- API request correlation ID

Payload contents, credentials, keys, and private user data should be excluded by default. Devices should retain bounded local diagnostics. Relays may aggregate operational metrics without becoming repositories of application content.

Diagnostic export must be privacy-safe and should make redaction rules explicit.

## Datastores

The system will require multiple stores with different ownership and lifecycle requirements:

```text
BeakrNet
├── Durable outgoing queue
├── Incoming deduplication records
├── Session and route recovery state
└── Credential and revocation cache

Beakr application
├── Blackboard repositories
├── Application data
├── Rule definitions
├── Rule execution history
└── User configuration

Relay and services
├── Bounded store-and-forward queues
├── Routing state
├── Operational configuration
└── Audit and rate-limit state
```

BeakrNet should define repository protocols where persistence is required without owning application schemas or Blackboard conflict policy.

Storage implementations should make durability, retention, migration, encryption, backup, and resource limits explicit.

## Rules and policy execution

Rules form a distinct architectural layer. They should not be hidden inside relay routing or user-interface code.

A rule needs at least:

- Stable ID and version
- Owner and authority
- Trigger
- Conditions
- Actions
- Required permissions
- Execution-location constraints
- Expiry and enabled state
- Idempotency behavior
- Resource limits
- Audit metadata

Rules should execute where the required data and authority reside:

- Device-local rules execute on the owning node.
- Blackboard rules execute on an authorized replica or designated coordinator.
- Relay-operational rules execute at the relay but must not interpret private payloads.
- Internet-triggered rules enter through an authenticated gateway.
- Safety-sensitive actions require confirmation or explicit delegated authority.

Rules should be versioned, testable, exportable, and preferably signed when distributed to another node. Execution should produce an auditable result linked to its triggering event.

Rule distribution and rule execution are separate permissions. Possessing a rule definition must not automatically grant authority to execute every action it describes.

## Application and Internet APIs

Applications should not need to construct raw BeakrNet envelopes. A supported API should expose product concepts such as:

- Send a message
- Publish or subscribe to Blackboard state
- Request or transfer data
- Negotiate a stream
- Discover capabilities
- Register or manage a rule
- Observe delivery and synchronization state

Internet clients should enter through a gateway or service API instead of exposing a device’s internal BeakrNet listener directly.

The external boundary requires:

- Scoped credentials
- Authorization checks
- Rate limits and quotas
- API versioning
- Request and correlation IDs
- Revocation
- Idempotency support
- Audit records
- Explicit query and mutation semantics

The public API is an adapter over Beakr capabilities, not the BeakrNet wire protocol itself.

## Cross-LAN and federated instances

The relay model permits communication between nodes that are not on the same LAN. Multiple LAN installations introduce additional requirements:

- Relay discovery and selection
- Relay federation
- Route advertisement
- Duplicate-path and loop prevention
- Trust between independently administered relays
- Store-and-forward ownership
- Conflict handling when several relays know the same node
- Metadata minimization between relays

Node identity remains independent of LAN, IP address, hostname, and relay. A logical session should survive movement among direct LAN, local relay, and Internet relay routes.

Relay federation must not silently expand a node’s trust domain. Route availability and authorization remain separate decisions.

## AI, MCP, Siri, and App Intents

AI and system integrations are adapters into the same authorized API and rule system. They are not privileged shortcuts around it.

```text
Siri and App Intents ─┐
MCP tools ────────────┼─> Beakr API and authorization layer
Application UI ───────┘          │
                                 ├─ Rules
                                 ├─ Blackboard repositories
                                 └─ BeakrNet sessions
```

Siri and App Intents are suited to local user actions and queries. MCP can expose selected Beakr capabilities to AI clients or allow Beakr to consume external tools.

Both require:

- Explicit scopes
- Human-readable action descriptions
- Confirmation for destructive actions
- Data minimization
- Audit trails
- Stable entity identifiers
- Clear separation between queries and mutations

AI-generated suggestions do not inherently possess execution authority. An AI client may propose a rule or action, but Beakr’s authorization and confirmation policies determine whether it can be stored or executed.

## Documentation boundaries

The concise BeakrNet architecture remains focused on networking identities, authenticated sessions, envelopes, delivery, routes, and transports. Detailed product concerns should be developed in dedicated design documents for:

- Storage and persistence
- Rules and policy execution
- APIs, gateways, and federation
- Logging and observability
- AI and system integrations

This separation keeps the networking substrate reusable while making the complete Beakr product architecture explicit.
