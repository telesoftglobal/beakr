# First-Class Node and Mesh Design Goals

Recorded October 30, 2026 from the product design discussion.

## Status and purpose

The agreed direction is that every Beakr device is a first-class node. Current platform constraints affect its capabilities and available routes, not its standing in the network. This principle guides future design, implementation review, and goals.

The concrete addressing syntax, route protocol, relay custody contract, remote administration contract, and implementation sequence below are proposals requiring design work. Recording this direction does not implement these features or expand Release 1 acceptance scope. Existing relay, handoff, and delivery mechanisms should be assessed and reused before introducing new ones.

## Agreed principles

Every node has its own authenticated identity, network memberships, destinations, and delivery state. An Apple Watch remains the origin or recipient when an iPhone carries its traffic. A relay does not substitute its identity for the original sender or final recipient.

Do not encode rules such as “Watch nodes require an iPhone,” “only Macs relay,” or “a gateway can belong to only one network” in the networking core. Any implementation may support relay capability, subject to authorization, resources, and platform execution constraints. This does not require every device to implement every capability or remain continuously available.

Keep these concepts separate:

| Concept | Meaning |
|---|---|
| Identity | The authenticated node within a network; independent of its current address or route. |
| Capability | Operations and transports the implementation supports. |
| Availability | Connections, resources, and execution opportunities usable now. |
| Permission | What the node is authorized to do, including relaying or forwarding. |
| Routing policy | Selection among permitted available routes for a particular message. |

Platform adapters enforce OS and hardware constraints. The core consumes capabilities and availability rather than branching on device model. Capability advertisements are claims to validate, not authorization grants. Temporary unreachability or a failed probe must not revoke membership.

## Authority and multiple networks

Separate creating a network, registering its creator, hosting its authority, participating in messaging, and selecting a network in the UI. Creation should not implicitly disconnect an existing network. The creator should be enrolled as the initial authorized node through the normal creation lifecycle; this does not require activating that network's messaging runtime immediately.

The desired architecture allows a device to host authorities and participate in multiple networks independently of which network the UI displays. Authority permission is separate from reachability and peer count. Invitation issuance, redemption, approval, and credential installation are separate operations: an invitation is not itself completed membership. Offline issuance requires a defined signing and persistence contract; redemption and approval require access to the appropriate authority services.

An authority controls membership and credentials. It need not carry every application message. Relaying within a network and forwarding information across networks are separate permissions. Joining Hamilton and Garden must not automatically bridge them or grant either network access to the other's messages.

## Messaging as a service and service authority — November 5, 2026

Status: proposed design direction recorded from the product discussion. This section does not implement service roles, change the UI, or establish new R1 acceptance results. Define the behavior contract before implementation.

### Network foundation and Messaging service

Model Messaging as a service provided over a Beakr network. It can be a built-in, default service without being inseparable from the network itself.

The network supplies identity, membership, trust, and permitted connectivity. Messaging adds addressing recipients, composing, durable queues, delivery acknowledgements, and history. Other services can use the same network foundation.

### Service-specific Host and Co-Host roles

Associate Host/Co-Host roles with a particular service and network, while distinguishing two responsibilities:

- **Service authority:** permission to enable the service, grant access, and delegate service roles.
- **Service hosting:** running the components that the service requires.

A Host may receive both responsibilities, but that combination must be explicitly defined rather than inferred from hosting. For peer-to-peer Messaging, a central hosting device need not carry every message. An offline Host should not automatically prevent already-authorized peers from communicating within the applicable trust and permission limits.

Retain network-level authority for membership and for granting service authority. A Messaging Co-Host does not automatically gain permission to change network ownership or administer unrelated services. The exact delegation, revocation, failover, and disconnected-operation rules remain to be specified.

### Proposed UI hierarchy

| Location | What it describes |
| --- | --- |
| Network | Membership and peer connectivity |
| Members / Nodes | Participating actors and devices, reachability, scoped roles |
| Services → Messaging | Conversations, mailboxes, queues, service availability |
| Messaging → Administration | Host/Co-Host assignments and messaging permissions |
| Network → Administration | Ownership, membership policy, and service delegation |

The blue messaging bubble may remain temporarily as the current messaging-selection indicator. Eventually, opening a network or service should primarily navigate to it; participation and hosting should have explicit controls where needed. This is a proposed UI model, not a claim that the current single-messaging-network implementation already supports concurrent service participation.

### Next design step

Write a short behavior specification before restructuring the UI or renaming existing authority controls. Include concrete scenarios:

- Host offline, authorized peers online: define which communication continues and which administrative operations wait.
- Co-Host grants permission while disconnected: define whether this is allowed, how its authority is verified, and how conflicting grants or revocations reconcile after reconnection.

Use the agreed behavior to shape the UI and implementation.

## Addressing and routes

Proposed logical destination:

```text
NetworkID + NodeID + ServiceID
```

An illustrative representation is `beakr://<network-id>/<node-id>/messages`. This is not an adopted URI scheme or wire format. Define canonical encoding, versioning, and service semantics before implementation. A local ProfileID is not a substitute for the shared NetworkID. Per-network identities remain compatible with this model; no globally correlatable device identity is required.

A destination identifies who should receive the message. A route identifies how to reach it now. The same destination may have several direct endpoints and authorized relay paths. Display names and IP addresses are not identity or proof of membership. Preserve interface and scope information with transport endpoints.

For example, a Watch can keep the same destination while the available path changes:

```text
Watch → iPhone → Mac
Watch → Mac
Watch → another authorized node → Mac
```

These are architectural possibilities, subject to actual platform support. They do not promise direct Watch connectivity on a particular OS or predict Apple's future APIs.

Discovery finds candidate endpoints. Authentication establishes the peer's identity and membership. Route exchange describes reachability. Probes provide limited evidence about current responsiveness. None substitutes for the others.

Next-hop routing is the proposed starting point: each relay selects the next permitted hop while preserving the final destination. A sequence of node IDs embedded in a message would instead be source routing. URI formatting alone supplies neither mechanism. General flooding and unrestricted multi-hop routing are not required to establish this model.

## Transport independence and peer-to-peer Wi-Fi

LAN, Apple peer-to-peer Wi-Fi commonly discussed as AWDL, and future WatchConnectivity or other adapters are ways to carry traffic. They must preserve logical identity, network boundaries, and delivery semantics. Use supported Apple APIs rather than depending on a hard-coded interface name or internal radio implementation.

Multiple discoveries of one authenticated node must not create duplicate members. Losing one path must not imply all paths are lost. Route changes must preserve message identity so retries can be deduplicated. Do not assume that enabling peer-to-peer Wi-Fi provides application mesh forwarding, durable storage, or continuous background execution.

## Durable relay and delivery

Ordinary mesh routing and delivery across an outage are different requirements. Beakr's proposed store-and-forward behavior allows an authorized node to retain a message until a next hop becomes available.

The future custody contract must distinguish local queueing, durable acceptance by a relay, final recipient acceptance, and any application processing acknowledgement. “Saved by iPhone” must not be displayed as “Delivered to Mac.” Define exactly when the sender may discard its copy and how responsibility survives crashes, restarts, expired credentials, and lost acknowledgements.

Preserve stable message IDs, bounded queues, expiry, retry backoff, duplicate suppression, and loop prevention. Do not promise exactly-once network delivery. Define payload confidentiality and integrity across relays explicitly; hop authentication alone is not an end-to-end protection contract. Cross-network forwarding needs an explicit authorization and provenance model.

## Dynamic multi-channel communication

A further product goal, carried forward from an earlier implementation, is dynamic multi-channel communication between nodes, including a blackboard channel. Nodes should be able to maintain several authorized logical conversations or shared-state exchanges concurrently, independently of the transport or route carrying them.

### Current foundation and remaining design

The current package is not limited to one semantic channel: `BeakrNetChannel` in `Sources/BeakrNetCore/Channel.swift` defines Control, Data, and Blackboard. The package also contains a Blackboard dispatcher, repository, persistence, and replication protocol. These foundations do not by themselves establish an application-facing dynamic channel lifecycle.

The user reports a single-channel experience in the current implementation. Distinguish that experience from package-level semantic channel support. Dynamic creation, negotiation, joining, subscription, closure, and presentation of logical channels require a separate implementation audit and contract.

Preserve the distinction between:

| Concept | Meaning |
|---|---|
| Semantic channel | Control, Data, or Blackboard identifies the meaning and protocol rules of an envelope. |
| Logical channel instance | A proposed independently identified conversation, stream, or shared-state exchange with its own lifecycle and permissions. |
| Transport connection | A path that can carry multiple logical channels; changing it must not silently change channel identity. |

A logical channel is not a priority class or a dedicated socket. The proposed model must preserve existing semantic channel rules. Whether dynamic instances use existing session, mailbox, service, or blackboard space identifiers, or require a new identifier, remains an explicit design decision. Do not add a second competing identity model without mapping the existing abstractions first.

### Design requirements

- Discover and negotiate supported channel semantics, schema versions, and resource limits; reject unsupported combinations explicitly.
- Allow authorized logical instances to open, coexist, and close at runtime without restarting the node or unrelated channels.
- Scope channel identity, participants, permissions, and persistent state to the appropriate Beakr network. Discovery or subscription alone grants no access.
- Define lifecycle ownership, participant changes, subscription cancellation, restart recovery, and behavior after membership revocation.
- Preserve channel and message identity across direct connections, relays, and transport handoff.
- Specify ordering, acknowledgement, durability, expiry, and retry semantics per channel contract. Shared-state replication and message delivery need different acceptance rules.
- Bound per-channel and aggregate queues, subscriptions, and work. Apply backpressure and fair scheduling so a busy channel cannot starve control or unrelated work.
- Keep protocol semantics above the transport; adapters carry envelopes without interpreting product state.

### Blackboard behavior

The blackboard goal is shared replicated state with authorized readers and writers, synchronization after disconnection, and explicit conflict handling. A blackboard is not merely a broadcast message stream. Subscriptions may signal that state changed; they do not replace canonical state or recovery synchronization.

Reuse and review the existing [Blackboard Replication Design](Blackboard-Replication-Design.md), including space identities, causal operations, snapshots, incremental synchronization, and application-owned conflict resolution. Map blackboard spaces and subscriptions into the dynamic channel model rather than replacing this work or silently choosing last-writer-wins behavior.

Future acceptance should demonstrate concurrent Data and Blackboard activity, opening and closing one logical instance without disrupting another, independent access controls, bounded load and fairness, route handoff, offline edits and conflicts, restart recovery, and isolation between networks. These are future goals, not newly completed R1 acceptance results.

## Permissioned remote node administration

Remote administration is a device-neutral design goal. An authorized node may inspect or configure another node through the same destination and routing model used for other services. A larger screen improves the administration interface; it does not confer authority. A Watch remains a full node whether it administers another device or receives a configuration command.

Separate these permissions:

| Permission | Scope |
|---|---|
| Observe | Read authorized status, capabilities, and configuration. |
| Configure | Change explicitly permitted settings on a specified target node. |
| Administer membership | Approve, revoke, or change network membership and roles. |

Hosting a network authority must not automatically grant unrestricted control of member devices or their other networks. The target enforces authorization for each operation. Relays carry requests without acquiring administrative privilege. Authenticate the originating administrator and preserve the command's integrity across relays; possession of an authenticated connection from the next hop alone is insufficient.

Illustrative flow:

```text
Administration UI → direct connection or authorized relay
                  → target validates request and permission
                  → target applies and persists change
                  → correlated result returns to administrator
```

The proposed management contract requires:

- Capability discovery describing supported operations, settings, schema versions, and applicable limits.
- Authorization scoped to the actor, target, network, and operation, with explicit delegation and revocation semantics.
- Expected configuration versions so concurrent or stale edits fail explicitly instead of silently overwriting newer state.
- Stable command IDs, durable result tracking, and safe retry behavior so a lost reply does not repeat an accepted change.
- Distinct queued, accepted, applied, rejected, expired, and failed outcomes; transport delivery alone does not prove that configuration changed.
- Expiry and authorization checks at execution time for queued commands, including a defined policy when current authorization cannot be established.
- Validation and recoverable application of changes. Connectivity or trust changes need a staged confirmation or rollback mechanism that survives restart and does not strand the node.
- An audit trail identifying the requesting actor, target, operation, and outcome without exposing credentials or sensitive configuration values.
- Local consent where required by target policy or the platform. Remote administration cannot bypass OS permissions.

Before implementation, define atomicity, crash recovery, result retention, delegation, and rollback behavior for each operation class. Begin with observation and a bounded set of reversible configuration changes. Reuse the existing permissioned command and Control protocol work where appropriate; this goal does not authorize arbitrary remote code execution or a general shell.

## Accountless enrollment and permission grants using platform security

BeakrNet should support administrative permissions without maintaining administrator accounts, passwords, or a separate user login system. In this paper, an administrator is an authorized actor exercising a permission, not a BeakrNet account type. Platform security protects credential use; BeakrNet grants determine the operations a credential may authorize.

Distinguish the following relationships even if some share an enrollment workflow:

| Relationship | Meaning |
|---|---|
| Node enrollment | An authenticated node is admitted to a particular Beakr network. |
| Service or capability registration | A node advertises a supported function; this alone grants no permission. |
| Channel participation | A credential may read, write, or subscribe to specified logical channels or blackboard spaces. |
| Administration grant | A credential may perform specified operations on specified targets. |
| Delegation | An authorized credential grants a permitted subset of its authority to another credential. |

On Apple platforms, evaluate Keychain access controls and hardware-backed keys where supported and suitable for the required operations. Apple documents gating Keychain access with user presence, using biometrics or an allowed passcode fallback: [Keychain authentication guidance](https://developer.apple.com/documentation/LocalAuthentication/accessing-keychain-items-with-face-id-or-touch-id). Exact key types, accessibility policies, authentication requirements, and platform availability need validation during implementation.

An illustrative interactive flow is:

```text
Person reviews a specific configuration change
    → platform security permits use of a protected signing key
    → originating node signs the command and its target context
    → target verifies the credential, grant, freshness, and command
    → target applies or rejects it and returns an auditable result
```

Successful local authentication does not itself identify a person to a remote node or establish network authority. A shared Apple Account, device ownership, a display name, or an unlocked device must not implicitly grant BeakrNet administration rights. A command signature proves use of a key; any stronger claim about fresh human approval requires an explicitly designed and validated assurance mechanism. Do not label every signed background command as user-approved.

Separate interactive approval from unattended operation. Routine monitoring, relaying, and synchronization need narrowly scoped credentials or grants with suitable background accessibility. Sensitive changes may require fresh local approval. Neither path may bypass the target's authorization checks. Keep platform-specific key access behind adapters so the node and grant model does not depend on device class or a particular biometric mechanism.

Before implementation, define grant issuer authority, network and target scope, permitted operations, expiry, delegation limits, revocation, replay protection, and behavior when current authorization cannot be established. An issuer cannot delegate permissions it does not hold or is not permitted to delegate. Bind commands to their intended target, network, operation, and relevant configuration version.

Define recovery for a lost device, unavailable protected keys, key rotation, and the loss of the last administrative credential. Recovery must use an explicit authorized process, not silently promote another member. Audit records should identify the credential and applicable grant without claiming a verified human identity that the system has not established. Map this model to existing enrollment and permissioned command work before adding new credential formats.

## Operational observability and configuration feedback

Remote administration should support a measurable workflow: observe, diagnose, change configuration, verify the result, and retain or roll back the change. Monitoring is a device-neutral, permissioned capability; a larger screen can aggregate reports but does not acquire access merely by presenting an administration UI.

| Area | Proposed observations |
|---|---|
| Node | Availability, capabilities, resource pressure, and last report time. |
| Route and transport | Latency, throughput, failures, reconnects, and route changes. |
| Logical channel | Queue depth, oldest queued item, retries, backpressure, and delivery latency. |
| Blackboard | Synchronization progress, pending operations, conflicts, and replica freshness. |
| Configuration | Applied version, change history, and measurements before and after a change. |

Scope each measurement to its node, network, route, or channel, with defined units, sampling interval, and freshness. Distinguish zero activity from unsupported, unavailable, or stale measurements. Sleeping nodes and delayed relay reports must not appear to provide current observations. Define latency boundaries explicitly, particularly where device clocks are not synchronized.

Bound sampling, retention, report volume, and processing cost; apply backpressure to monitoring itself. Expose only authorized information and keep secrets and application payloads out of routine telemetry. A configuration change and a subsequent performance change can be correlated without claiming causation.

Begin with trustworthy observations and explicit configuration outcomes. Automated tuning remains future work requiring its own authorization, limits, and rollback policy.

## Proposed implementation goals

1. Audit existing identity, envelope, session, relay, and route abstractions against these principles; record gaps and migration needs.
2. Separate authority hosting, network participation, and UI selection, with explicit storage and lifecycle ownership.
3. Define a versioned destination and capability contract, route freshness, and authorization boundaries. Specify how membership removal invalidates routes and queued work.
4. Extend direct delivery with a bounded authorized relay path and durable custody semantics, reusing existing mechanisms where they satisfy the contract.
5. Define accountless permission grants and platform key protection, including delegation, revocation, recovery, and interactive versus unattended use. Define and validate permissioned remote administration, beginning with bounded observability and reversible settings; establish command authorization, persistence, result, and rollback contracts before enabling disruptive changes.
6. Add transports through adapters with demonstrated platform support. Consider wider multi-hop routing only after bounded relay behavior is proven.

This is a dependency proposal, not a release commitment. Release 1 hardware acceptance remains governed by the existing acceptance documents.

## Review and regression scenarios

- The same node appears through two transports: one member, multiple candidate routes.
- A direct route fails and delivery retries through a relay: unchanged destination and message identity; no duplicate application acceptance.
- A sleeping or unavailable node returns: membership is preserved and eligible queued work resumes.
- A relay crashes before or after durable acceptance, or an acknowledgement is lost: responsibility and retry behavior remain defined.
- A stale route, relay cycle, or expired message cannot cause indefinite forwarding; queue exhaustion has an explicit outcome.
- A member is revoked while traffic is queued: subsequent relay and delivery decisions enforce the applicable trust policy.
- A device joins two networks: identities, credentials, queues, and authorization remain isolated; forwarding requires an explicit rule.
- Capabilities or execution availability change without a device identity change; no permanent device-class restriction is introduced.
- Creating a network or changing UI selection does not implicitly tear down unrelated active services.
- Remote observation and configuration enforce separate permissions; authority hosting or relay capability alone cannot authorize a change.
- A repeated administration command, lost reply, or target restart preserves one accepted change and a recoverable result.
- Concurrent configuration edits, expired queued requests, and revoked administrator permissions produce explicit outcomes without unintended mutation.
- A connectivity-changing command fails or loses its confirmation path: the defined recovery mechanism restores manageable operation.
- Administration works through an authorized relay without changing the requesting actor or final target, and required local consent remains enforced.
- Local authentication succeeds but the credential lacks a target-specific grant: the operation is rejected. Background credentials cannot perform interactive-only operations.
- Expired or revoked grants, overbroad delegation, replayed commands, and cross-network requests cannot authorize mutation.
- Lost or rotated keys use the defined recovery path; no member is implicitly promoted to administrator.
- Monitoring distinguishes zero, missing, unsupported, and stale measurements; a sleeping node or delayed report cannot be mistaken for a current healthy sample.
- Telemetry permissions, retention, and sampling limits hold under load, and configuration outcomes remain observable without exposing sensitive values.

Use deterministic tests for protocol and persistence behavior, then hardware tests for transport reachability, background execution, energy constraints, and recovery. UI diagnostics should distinguish direct connection, relay reachability, and queued delivery rather than treating all three as one online state.

## Related design and external references

- [Multi-network planning](BeakrNet-Multi-Network-Planning-and-Discussion.md) and [permissioned networking contract](Permissioned-Networking-Contract.md).
- [Product goals](Beakr-Product-Goals.md), [next milestones](Next-Milestones.md), and [R1 adverse conditions acceptance](R1-Adverse-Conditions-Acceptance.md).
- [Thread addressing](https://openthread.io/guides/thread-primer/ipv6-addressing) illustrates the distinction between a topology-independent endpoint identifier and a routing locator.
- [Bluetooth Mesh directed forwarding](https://www.bluetooth.com/mesh-directed-forwarding/) provides context for managed flooding and directed paths; Beakr has not selected Bluetooth Mesh as its protocol.
- [Apple networking API guidance](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) and [Network endpoint types](https://developer.apple.com/documentation/Network/NWEndpoint#Endpoint-Types) describe supported connectivity and endpoint abstractions, not a complete Beakr relay contract.
