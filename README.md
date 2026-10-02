# BeakrNet

BeakrNet is an independent experimental networking substrate for Beakr. It explores authenticated logical sessions that can survive changes between local, relayed, and device-adjacent transports.

The package deliberately has no dependency on the existing Beakr prototype, XYZ replication models, or application data stores.

## Initial scope

- Stable node, session, message, and transport identifiers
- Transport-neutral envelopes and capabilities
- Logical session state and transport bindings
- Duplicate-message detection
- An in-memory transport for deterministic tests

Bonjour, Internet relay, WatchConnectivity, production credentials, and application integration are later milestones.

Run the package tests with:

```sh
swift test
```

Run the deterministic transport-handoff experiment with:

```sh
swift run BeakrNetHandoffLab
```

Create a development TLS pre-shared key, then run the localhost relay:

```sh
swift run BeakrNetNodeCLI psk /tmp/beakrnet-relay.psk
swift run BeakrNetRelayServer 7878 /tmp/beakrnet-relay.psk
```

Create two development identities and note the receiver's printed Node ID:

```sh
swift run BeakrNetNodeCLI identity /tmp/beakrnet-node-a.key
swift run BeakrNetNodeCLI identity /tmp/beakrnet-node-b.key
swift run BeakrNetNodeCLI receive /tmp/beakrnet-node-b.key 10 /tmp/beakrnet-relay.psk
swift run BeakrNetNodeCLI send /tmp/beakrnet-node-a.key 10 <node-b-uuid> /tmp/beakrnet-relay.psk
```

The relay uses TLS with a development PSK and separately authenticates possession of a self-sovereign node identity. It does not yet use authority-issued credentials and must not be exposed as a production service.
