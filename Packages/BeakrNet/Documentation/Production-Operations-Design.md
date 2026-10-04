# Production Operations Design

Milestone 11 defines the deployable BeakrNet service profile. It does not turn laboratory command-line tools into production services by configuration alone.

## Production profile

`BeakrNetOperations` owns validated deployment configuration, admission controls, privacy-safe audit and telemetry contracts, backup manifests, and recovery-drill coordination. Protocol and cryptographic verification remain in their existing modules.

A production profile requires:

- Authority signing keys held by secure hardware or an external managed key service. Filesystem authority private keys are invalid.
- Public HTTPS enrollment and revocation endpoints with explicit service authentication policy.
- Mutual TLS or independently signed workload identity for privileged service-to-service calls. Development PSKs are invalid.
- Explicit request, identity, source, and global rate limits with bounded queues and generic overload responses.
- A selected offline revocation grace interval. It cannot silently default and cannot exceed policy bounds.
- Encrypted, integrity-committed backups with retention, restore verification, and separation from online signing credentials.
- Bounded privacy-safe audit retention and telemetry containing reason codes and counts rather than payloads, credentials, keys, filenames, or private state.

## Key custody and service authentication

Key custody adapters expose signing, public-key retrieval, key generation identity, availability, and audit identifiers; private key bytes are never returned. Rotation requires a verified predecessor/successor transition and an overlap window. Recovery uses the separately pinned offline recovery authority already defined by the protocol.

Every administrative endpoint authenticates the workload identity and authorizes a named operation. Public signed revocation snapshots remain publicly readable, but snapshot publication and enrollment issuance are privileged. TLS authenticates the service endpoint; signed protocol content remains independently verified.

## Admission and abuse controls

Admission is enforced in layers: per source, per authenticated identity, per operation, and global. Limits use deterministic token buckets with bounded state and idle eviction. Authentication failures, malformed requests, and resource exhaustion consume capacity. Failure responses do not reflect request bodies or disclose whether an identity exists.

## Backup and restore

Backup manifests bind format version, environment, authority generation, creation time, monotonic sequence, component names, byte lengths, and SHA-256 digests. Backup bytes are encrypted outside the manifest boundary by an injected custody service. Restore verifies every component before staging and atomically activates only a complete, non-rollback set. Authority private keys are restored through their custody provider, never from ordinary application backup files.

## Rollout and recovery drills

Deterministic coordinators model authority rotation, backup restore, overload, clock disagreement, stale revocation state, partial rollout, and rollback. A rollout advances only when the configured health gate succeeds. Failure retains the previously trusted generation and configuration. A missed authority overlap requires the explicit offline recovery package; operational convenience never bypasses trust.

## Completion criteria

Tests cover invalid production profiles, key-custody outage, identity and global overload, bounded limiter state, audit retention, backup corruption and rollback, restore staging, rotation and recovery drills, endpoint clock disagreement, stale revocation state, partial rollout, and safe configuration rollback.

## Implemented validation

`BeakrNetOperationsTests` exercises secure-profile rejection, deterministic overload and refill, bounded principal and audit state, privacy-safe metric counters, custody outage, corrupt and incomplete backups, generation and sequence rollback, restore resource limits, activation only after complete verification, stale revocation state, clock disagreement, partial rollout, and successful next-generation activation. Provider adapters are intentionally injected; tests do not require cloud services, Apple networking services, or credentials.
