# BeakrNet

BeakrNet is an independent experimental networking substrate for Beakr. It explores authenticated logical sessions that can survive changes between local, relayed, and device-adjacent transports.

The package deliberately has no dependency on the existing Beakr prototype, XYZ replication models, or application data stores.

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

The transport meaning of Control, Data, and Blackboard is implemented. Their application-level protocols are the next milestones. WatchConnectivity, Bluetooth Low Energy, application rules, public APIs, and user-interface integration remain later work.

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
swift run BeakrNetCredentialTool issue /tmp/beakrnet-authority.key /tmp/beakrnet-node-a.key /tmp/beakrnet-node-a.credential development ping 86400
swift run BeakrNetCredentialTool issue /tmp/beakrnet-authority.key /tmp/beakrnet-node-b.key /tmp/beakrnet-node-b.credential development ping 86400
swift run BeakrNetCredentialTool create-revocations /tmp/beakrnet-authority.key /tmp/beakrnet-revocations.json
swift run BeakrNetRelayServer 7878 /tmp/beakrnet-relay.psk /tmp/beakrnet-authority.pub development /tmp/beakrnet-revocations.json
swift run BeakrNetNodeCLI receive /tmp/beakrnet-node-b.key 10 /tmp/beakrnet-relay.psk /tmp/beakrnet-node-b.credential
swift run BeakrNetNodeCLI send /tmp/beakrnet-node-a.key 10 <node-b-uuid> /tmp/beakrnet-relay.psk /tmp/beakrnet-node-a.credential
```

The relay command-line lab uses TLS with a development PSK and separately authenticates authority-issued node credentials and possession of the node identity. The shared development PSK, command-line authority material, and laboratory server are not a production deployment configuration.

See [Implementation Plan](Implementation-Plan.md) for completed work, [Next Milestones](Next-Milestones.md) for the ordered roadmap, and [Package Architecture and Testing](Package-Architecture-and-Testing.md) for dependency and validation boundaries.
