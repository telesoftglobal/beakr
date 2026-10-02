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

The relay uses TLS with a development PSK and separately authenticates possession of a self-sovereign node identity. It does not yet use authority-issued credentials and must not be exposed as a production service.
