# Host API, Storage, and Lifecycle Design

Milestone 10 exposes supported application concepts without requiring applications to construct envelopes, select transports, or coordinate protocol repositories directly.

## Module boundary

The platform-neutral `BeakrNetHost` target depends on `BeakrNetCore`, `BeakrNetControl`, `BeakrNetData`, `BeakrBlackboard`, `BeakrNetTransfer`, `BeakrNetSecurity`, and `BeakrNetAuthority`. It contains no SwiftUI and does not import Network, Security, notification, or background-execution frameworks. Apple applications adapt OS lifecycle and permission events into this boundary.

## Application API

The host API exposes:

- Send message and perform request operations using typed Data operations, deadlines, cancellation, and idempotency.
- Read, mutate, resolve, and subscribe to named Blackboard spaces through repository concepts.
- Start, resume, cancel, and inspect verified Data transfers.
- Observe delivery, synchronization, credential, route, permission, storage, and lifecycle state.
- Export bounded privacy-safe diagnostics.

Raw envelopes, route candidates, transport generations, TLS identities, and persistence file layouts are not application API.

## Repositories and recovery

Injected repository protocols own pending Data work, incoming idempotency, Blackboard state, transfer staging, host checkpoints, credentials, and diagnostics. A canonical host checkpoint records only coordination state and monotonic generations; protocol repositories remain authoritative for their data.

Startup proceeds in order: open and validate repositories, restore pending work, restore credential/revocation state, reconcile expired work, then permit routes and application dispatch. Corrupt or unsupported durable state fails closed. No callback is published as ready before recovery completes.

## Lifecycle model

Lifecycle states are `starting`, `foreground`, `background`, `suspended`, `locked`, `stopping`, `stopped`, and `failed`. Transitions are explicit and idempotent. Background execution is a bounded opportunity represented by an injected lease with an expiration signal. Expiration stops new work, atomically checkpoints, and leaves unfinished durable operations pending for the next activation.

Device lock may make credentials or protected files unavailable. The host reports `locked`, closes routes requiring unavailable material, retains durable work, and retries recovery only after an unlock event. It never weakens Keychain accessibility or trust policy.

## Permissions and reachability

Local Network and notification permission states are `unknown`, `granted`, `denied`, and `restricted`. Local Network denial disables LAN discovery/listening but leaves authenticated relay eligibility unchanged. Notification denial removes push hints only; scheduled and foreground refresh remain authoritative. APNs or other wake events request refresh and never carry authoritative state.

## Storage pressure

Storage pressure is `normal`, `constrained`, or `critical`. Constrained state stops admission of new large transfers and may run policy-approved cleanup of expired staging. Critical state additionally pauses new durable application work after checkpointing. Live state, unresolved Blackboard conflicts, credentials, unexpired pending operations, and published application files are never silently evicted.

## Credentials and revocation

Credential renewal and revocation refresh remain owned by their existing verified controllers. The host schedules and invokes them, reports their state, and coordinates route suspension during unavailable or revoked identity state. Renewal never replaces a usable identity until the replacement has been fully verified and installed.

## Diagnostics and synchronization state

Diagnostics use a fixed vocabulary containing timestamps, subsystem, safe reason code, public identifiers, and numeric counts. They exclude payloads, Blackboard values, transfer metadata and paths, credentials, keys, tokens, peer-provided filenames, and private application errors. Export is bounded by event count and encoded bytes and is canonically ordered.

Visible synchronization state is derived from repository facts: pending messages, Blackboard frontier/cursor status, active transfers, last successful refresh, retry deadline, lifecycle, permission, and storage-pressure state. UI observes this value but remains outside the package.

## Completion criteria

Deterministic tests cover termination/relaunch, background expiration, lock/unlock, denied permissions, storage pressure, credential renewal while work is queued, revocation refresh, recovery ordering, corrupt checkpoints, diagnostic redaction/bounds, and unchanged pending operation identity across lifecycle transitions.
