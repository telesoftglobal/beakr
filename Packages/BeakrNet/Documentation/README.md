# BeakrNet

BeakrNet is an independent experimental networking substrate for Beakr. It explores authenticated logical sessions that can survive changes between local, relayed, and device-adjacent transports.

The package deliberately has no dependency on the existing Beakr prototype, XYZ replication models, or application data stores.

## Current R1 architecture

[Beakr network architecture and operations](Beakr-Network-Architecture-and-Operations-2026-11-07.md) ([PDF](Beakr-Network-Architecture-and-Operations-2026-11-07.pdf)) explains network and node identities, permissions, authority hosting, peer message delivery, discovery, trust maintenance and recovery. It distinguishes implemented R1 behavior from future design proposals.

[R1 Issues and Deferred Work](R1-Issues.md) records larger architecture work, smaller follow-ups and accepted evidence limitations after R1 signoff. It is a follow-up register, not a reopening of R1 or an implementation authorization.

## Agreed design direction

[Restricted shared status service](Shared-Status-Service-Proof-2026-11-08.md) records the November 8 post-R1 proof and selected-runtime integration: Data request/reply reuse, default-off per-peer sharing, device-detail controls, bounded outcomes and fixture evidence. A user-operated Mac/physical-iPhone exchange now confirms default denial, an explicitly allowed snapshot and subsequent denial, with correlated console events and screenshots. An additional Shared Status menu popover (Mac) / bottom sheet (iPhone) now reuses the inline controls and state; builds pass, visual verification of this later UI remains pending. Full accessibility/layout acceptance and performance benchmarking remain outside that evidence.

[First-Class Node and Mesh Design Goals](Node-Identity-Routing-and-Relay-Principles-2026-10-30.md) records the October 30 agreement that every device is a first-class node, with capabilities and routes independent of device category. It separates agreed principles from proposed addressing, authority hosting, and durable relay work; it does not expand R1 scope.

## Architecture proposal under review

[Permissioned Networking Object and Command Contract](Permissioned-Networking-Contract.md) defines proposed entity ownership, restricted command interfaces, persistence and recovery rules, acceptance scenarios, and a mapping to the current Release 1 code. It is a review document, not an implemented API or an expansion of Release 1 scope.

- [Entity Contract Template v1.1](Entity-Contract-Template-v1.1.md) ([printable PDF](Entity-Contract-Template-v1.1.pdf)) organizes entity definitions as Meaning, Facts, Control, Behavior, and Lifetime.
- [Entity Design Discussion and Release 1 Next Steps](Entity-Design-Discussion-2026-10-26.md) ([printable PDF](Entity-Design-Discussion-2026-10-26.pdf)) records the October 26 User/Actor, audit, and approval proposals, unresolved decisions, and the recommended R1 validation sequence. It does not authorize implementation of the proposed model.

- [R1 Message Submission Control Point](R1-Message-Submission-Control-Point.md) ([printable PDF](R1-Message-Submission-Control-Point.pdf)) maps current submission ownership, persistence and outcome boundaries, and the isolated R1 validation results.

## Implemented foundation

- Stable node, session, message, and transport identifiers
- Transport-neutral envelopes and capabilities
- Logical session state and transport bindings
- Duplicate-message detection
- An in-memory transport for deterministic tests
- Bounded persistent relay queues with reserved Control capacity
- Authenticated relay and Bonjour/Network-framework LAN transports
- Deterministic route selection and relay/LAN handoff
- Certificate enrollment, renewal, rotation, recovery, and revocation distribution
- Opt-in signed Apple-platform integration coverage
- Durable Context and Store identities with network reattachment and Context-owned message persistence

The Control, Data, Blackboard and transfer protocol foundations are implemented at package level. The app integrates selected-network messaging; broader application service workflows remain separate work. WatchConnectivity, Bluetooth Low Energy, application rules and broader public/UI service integration remain later work.

`BeakrNetRelayTransport` now provides the reusable encrypted relay client used by the command-line node, including credential authentication, incoming-envelope delivery, connection diagnostics, and automatic reconnect with backoff.

Run the package tests with:

```sh
swift test
```

Run the deterministic transport-handoff experiment with:

```sh
swift run BeakrNetHandoffLab
```

Create a development TLS key and credential authority:

```sh
swift run BeakrNetNodeCLI psk /tmp/beakrnet-relay.psk
swift run BeakrNetCredentialTool create-authority /tmp/beakrnet-authority.key /tmp/beakrnet-authority.pub
```

Create two development identities and note the receiver's printed Node ID:

```sh
swift run BeakrNetNodeCLI identity /tmp/beakrnet-node-a.key
swift run BeakrNetNodeCLI identity /tmp/beakrnet-node-b.key
swift run BeakrNetCredentialTool issue /tmp/beakrnet-authority.key /tmp/beakrnet-node-a.key /tmp/beakrnet-node-a.credential 7E570000-0000-4000-8000-000000000001 development ping 86400
swift run BeakrNetCredentialTool issue /tmp/beakrnet-authority.key /tmp/beakrnet-node-b.key /tmp/beakrnet-node-b.credential 7E570000-0000-4000-8000-000000000001 development ping 86400
swift run BeakrNetCredentialTool create-revocations /tmp/beakrnet-authority.key /tmp/beakrnet-revocations.json
swift run BeakrNetRelayServer 7878 /tmp/beakrnet-relay.psk /tmp/beakrnet-authority.pub 7E570000-0000-4000-8000-000000000001 development /tmp/beakrnet-revocations.json
swift run BeakrNetNodeCLI receive /tmp/beakrnet-node-b.key 10 /tmp/beakrnet-relay.psk /tmp/beakrnet-node-b.credential
swift run BeakrNetNodeCLI send /tmp/beakrnet-node-a.key 10 <node-b-uuid> /tmp/beakrnet-relay.psk /tmp/beakrnet-node-a.credential
```

The relay command-line lab uses TLS with a development PSK and separately authenticates authority-issued node credentials and possession of the node identity. The shared development PSK, command-line authority material, and laboratory server are not a production deployment configuration.

See [BeakrNet Functional Specification](BeakrNet-Functional-Spec.md) for user-visible system behavior, [Implementation Plan](Implementation-Plan.md) for completed work, [Next Milestones](Next-Milestones.md) for the ordered roadmap, [Package Architecture and Testing](Package-Architecture-and-Testing.md) for dependency and validation boundaries, [Blackboard Replication Design](Blackboard-Replication-Design.md) for replication, [Reliable Large Data Transfer Design](Reliable-Transfer-Design.md) for staged transfer semantics, [Host API, Storage, and Lifecycle Design](Host-Integration-Design.md) for application integration, [Context, Storage, and Synchronization Design](Context-Storage-and-Synchronization-Design.md) for durable user data and cross-device policy, [Authority-Managed Network Capabilities](Authority-Managed-Network-Capabilities.md) for the deferred service and provider policy model, and [Production Operations Design](Production-Operations-Design.md) for deployment constraints.

- [October 26 R1 recovery discussion](R1-Recovery-Session-2026-10-26.md) saves the restart investigation, repair, and successful hands-on result.
- [Startup text for October 27](Beakr-Startup-2026-10-27.md) carries the current state and constraints into the next conversation.

[Foreground Shared Status Shortcuts action](Shared-Status-Shortcuts-2026-11-08.md) documents the bounded caller implementation, eight adapter tests, successful Mac/iOS builds and pending user-operated Shortcuts verification.

The Shortcuts case is **parked at user request**: discovery works and execution reaches denial, but connection-scoped sharing conflicts with background/reconnect. The linked Shortcuts record contains the proposed persistent-per-peer permission design; it is not implemented.
