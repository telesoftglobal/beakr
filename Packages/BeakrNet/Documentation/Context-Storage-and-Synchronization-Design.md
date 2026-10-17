# Context, Storage, and Synchronization Design

Beakr is a secure data-communications foundation. It owns the reusable mechanisms needed to authorize devices, move opaque data, preserve it, and control its synchronization. It does not own domain interpretation, analysis workflows, dashboards, or AI prompts.

This design separates durable user data from replaceable network membership. Losing connectivity or forgetting a network must not implicitly destroy messages or datastore records.

## Scope boundary

The BeakrNet package family owns:

- Identity, permissions, trust, and secure network membership
- Peer discovery, authenticated transport, routing, delivery, acknowledgement, and retry
- Communication lifecycle and diagnostics
- Generic durable message and datastore primitives
- Provenance, integrity, retention, import, export, and migration mechanisms
- Declarative synchronization policy and bounded remote query mechanisms

Applications built above BeakrNet own:

- The domain meaning of payloads and datastore schemas
- Analysis such as interpreting Ripple network-performance measurements
- User workflows, dashboards, reports, and notifications
- AI prompts, recommendations, and domain-specific actions
- Translation of domain decisions into generic metadata, queries, and synchronization policy

A capability belongs in BeakrNet when unrelated applications need it to communicate or preserve opaque data securely. A capability belongs above BeakrNet when it must understand what that data means.

## Durable Context ownership

A `Context` is the durable user-facing workspace. Network connections are attached to a Context but do not own its content.

```text
Context
├── Connections
│   ├── Beakr network memberships
│   └── Future service or import connections
├── Content
│   ├── Message folders
│   └── Datastore folders
├── Synchronization policies
├── Domain rules and automations
└── AI access policy
```

The Context owns messages, datastore records, folder organization, and their lifecycle. A network membership provides communication authority and transport access. Removing that membership does not remove Context-owned content.

### Stable identities

| Identity | Purpose | Lifetime |
| --- | --- | --- |
| `ContextID` | Identifies the durable workspace | Independent of any network membership |
| `NetworkID` | Identifies a logical Beakr network | Stable across device enrollment changes |
| `MembershipID` or profile ID | Identifies one device enrollment | Replaceable when forgotten or re-enrolled |
| `StoreID` | Identifies a message store or datastore | Owned by a Context |
| `ContentItemID` | Identifies a message or datastore record | Independent of transport and membership |

Content retains provenance such as originating Network ID, membership or device identity, timestamps, schema, integrity metadata, and delivery history. Provenance does not make the originating connection the owner of that content.

## Network lifecycle semantics

Network availability and membership are separate states.

- **Offline** retains membership, credentials, and all content. The app waits or retries.
- **Disconnect or deactivate** stops communication while retaining membership and content.
- **Forget Network** removes the membership credentials and connection configuration while preserving Context content as an archive.
- **Delete Data** separately removes selected messages, stores, or the entire Context after explicit confirmation.

The application now preserves Context-owned message state when a joined network is forgotten. The confirmation states that messages are preserved and that forgetting cannot repair unavailable connectivity. Authority-owned network deletion remains a separate destructive operation.

When a device later joins a network with a known `NetworkID`, Beakr should offer to attach the new membership to the existing Context. A different network must not merge automatically; the user chooses whether to attach it to an existing Context, create a new Context, or import selected content.

## Message stores and datastore folders

Message stores and datastores share infrastructure concerns but not application schemas.

BeakrNet storage primitives provide:

- Durable records and stable identifiers
- Folder or collection membership
- Provenance and integrity metadata
- Explicit retention, archival, and deletion
- Encryption and access-control metadata
- Schema versioning and migration hooks
- Bounded queries, synchronization cursors, and change observation
- Import and export

An application datastore, such as Ripple performance analysis, defines its own record schema and interpretation above these primitives. Removing a network connection cannot silently evict published application data, message history, or datastore records.

## Synchronization policies

BeakrNet supports rules that control data movement. Domain rules remain in the application layer.

Appropriate synchronization policies include:

- Synchronize unread messages to Apple Watch.
- Send summaries and metadata while leaving attachments on iPhone.
- Retain only the latest day of projected records on Watch.
- Permit Watch to query a specified iPhone datastore.
- Defer large transfers until Wi-Fi or charging.
- Prevent a confidential datastore from leaving its Mac.
- Grant a device read access without modification authority.

Domain rules such as diagnosing Ripple measurements or asking an AI to recommend corrective action remain above BeakrNet.

### Replication, query, and capability

The synchronization layer exposes three separate primitives:

1. **Replication policy** determines what is proactively synchronized.
2. **Remote query** retrieves authorized data that was not replicated.
3. **Capability policy** determines which device can read, query, append, modify, synchronize, or administer each store.

A constrained device receives a projection rather than an automatic copy of an entire store:

```text
Source: Ripple datastore on iPhone
Destination: Apple Watch
Selection: latest records marked important
Projection: timestamp, status, and summary
Retention: 24 hours
Attachments: on demand
```

The destination may express what it wants, but the source store determines what it is willing to disclose. The effective result is the intersection of destination demand, source disclosure policy, device capability, and current resource constraints.

## Rule representation and execution

Synchronization policies are declarative and operate on stable metadata such as record type, creation date, priority, size, tags, source, and sensitivity classification. BeakrNet does not accept arbitrary executable code from a peer.

Distributed policies are versioned, testable, resource-bounded, and signed when authority must cross devices. Possessing a policy definition does not grant authority to execute every action it describes. Evaluation produces auditable decisions without recording private payload content.

Execution occurs where the data and authority reside:

- A source device enforces disclosure and retention policy.
- A destination device enforces local admission and storage limits.
- A relay routes authorized envelopes but does not interpret private payloads.
- A remote query executes at the authorized store and returns a bounded projection.

The generic policy model and enforcement mechanisms may live in a dedicated `BeakrNetSync` module. User-facing editors and domain-specific rule construction remain in consuming applications.

## AI and system access

Each Context and store independently declares whether data is available for on-device analysis, cloud analysis, neither, or a redacted projection. Siri, App Intents, MCP, and cloud AI are authorized adapters into the same query and policy boundaries; they do not bypass them.

AI-generated suggestions have no inherent execution authority. Destructive mutations, disclosure to cloud services, and changes to synchronization policy require the same scopes and confirmation rules as any other client.

## Migration direction

The current application stores message state under a network profile. Migration proceeds in stages:

1. Introduce stable Context and Store identities without changing transport behavior.
2. Move message persistence into Context-owned storage while preserving Network ID provenance.
3. Change Forget Network to delete only membership credentials and connection configuration.
4. Retain forgotten-network content as an archived Context.
5. Reattach a replacement membership when the same Network ID is joined again.
6. Add generic datastore folders, synchronization policy, remote query, and per-store AI permissions.

Migration must be transactional and recoverable. Existing messages cannot be silently discarded, duplicated, or reassigned to an unrelated Context.

## Current implementation

The first persistence milestone is implemented:

- `ContextID` and `StoreID` are stable Core identifiers.
- `PersistentContextRegistry` associates known Network IDs with durable Context and message-store identities.
- Detaching the last membership archives the Context while retaining its known Network ID.
- A replacement membership for that Network ID reuses the existing Context and Store ID.
- Host runtime storage accepts a Context-owned message-state URL while keeping trust, relay, checkpoint, transfer, Blackboard, and diagnostic state under the profile root.
- Existing profile-owned message state is copied through a same-volume temporary file into the Context store, opened and validated there, and only then removed from its legacy location.
- Forget Network removes credentials and profile-owned runtime state but preserves the Context message store.

User-facing archived-Context browsing, explicit attachment choices for unrelated networks, generic datastore folders, declarative synchronization policies, and remote queries remain future milestones.

## Completion boundary

The secure communications foundation is functionally complete when identity and trust, transport and delivery, communication management, generic durable stores, lifecycle semantics, synchronization policy, remote query, migrations, and deletion boundaries are reliable. Further development should primarily harden security, performance, compatibility, diagnostics, and operational behavior rather than add domain features.
