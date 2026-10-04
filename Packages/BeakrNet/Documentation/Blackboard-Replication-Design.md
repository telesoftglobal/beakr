# Blackboard Replication Design

This document closes the Milestone 8 design gate. Blackboard is replicated application state carried by the Blackboard channel. It is not durable Data and transports do not interpret it.

## Module and dependency boundary

The reusable implementation is the platform-neutral `BeakrBlackboard` library in the BeakrNet package. It depends on `BeakrNetData`, `BeakrNetControl`, and `BeakrNetCore`, and imports no UI, Network, Security, or application target. Product schemas and conflict-resolution decisions remain above this library.

## Identity

- `BlackboardSpaceID`, `BlackboardRecordID`, `BlackboardReplicaID`, `BlackboardOperationID`, and `BlackboardSubscriptionID` are independent UUID-backed identifiers.
- A space also has a bounded human-readable name. Names are presentation metadata and never identity.
- A replica ID is stable for one repository replica. It is not a Node ID, although authorization binds an authenticated Node ID to a space role.
- Every operation has an immutable operation ID and a causal dot consisting of its replica ID and strictly increasing replica counter.

## Causality and record model

A causal frontier is a sorted list of replica counters. Dictionary encoding is deliberately avoided so canonical ordering is explicit. An operation carries the frontier it observed and its next dot. A repository accepts an operation only when all dependencies are locally known and the dot is exactly the next counter for that replica. Missing dependencies are synchronized before the operation is retried; counters cannot jump or roll back.

Each record is an observed-remove multi-value register. A causally later write or tombstone replaces versions it observed. Concurrent versions are retained and sorted by operation ID. A write/delete race is therefore an explicit conflict rather than an implicit resurrection or deletion. Wall-clock time is diagnostic and retention metadata only; it never determines a winner.

Conflict resolution is an application-owned operation. It names the exact conflicting operation IDs, causally observes all of them, and supplies either a replacement value or tombstone. A partial or stale resolution fails closed.

## Values and attachments

Values are bounded opaque canonical application bytes with a schema identifier and schema version. The Blackboard layer does not decode product state. Attachments are bounded references containing a Data-transfer identifier, byte length, and content digest. Attachment bytes never enter Blackboard snapshots or journals.

## Authorization

Membership is authoritative per space and maps authenticated Node IDs to `reader`, `writer`, or `owner` roles. Readers may fetch snapshots, journal entries, and subscriptions. Writers may additionally submit ordinary operations. Owners may update membership and approved compaction frontiers. Route availability and transport capability never grant membership.

Authorization is checked after authenticated-session acceptance and before repository reads, journal disclosure, subscription registration, or mutation. Membership revisions are monotonic; rollback is rejected.

## Canonical wire and persistence formats

Wire messages and persisted snapshots use independently versioned, sorted-key JSON with millisecond dates and canonical re-encoding checks. Blackboard envelopes use the Blackboard channel and one strict payload discriminator. Message kinds are snapshot request/response, incremental request/response, operation batch, subscription request/cancellation, and bounded protocol error.

A snapshot contains its space, membership revision, compaction generation, causal frontier, and records in identifier order. Each record contains its surviving versions in operation-ID order. A journal contains accepted operations in causal acceptance order after the snapshot frontier.

An incremental cursor contains the compaction generation and journal offset. A cursor from another generation or beyond the journal end fails with `compactionBoundaryMismatch`; the caller must request a snapshot. Snapshot plus journal replay must produce the same canonical state as uninterrupted operation.

## Compaction, retention, and bounds

Compaction is explicit. The proposed frontier must not roll back, exceed the repository frontier, or omit a retained conflict dependency. Tombstones are retained until the approved compaction frontier proves every active replica has observed them. The initial implementation never removes a tombstone merely because time elapsed.

Policies bound spaces, members, records, versions per record, journal operations, batch size, value bytes, attachment references, subscriptions, and encoded payload size. Admission fails before mutation when a bound would be exceeded. No implicit eviction may discard live state, conflicts, tombstones, or causal history.

## Synchronization and subscriptions

Peers request either a canonical snapshot or operations after a known cursor/frontier. Duplicate operation IDs are idempotently rejected without mutation. Operations with missing or impossible causal metadata fail closed. Delivery retries preserve operation and envelope identity across relay/LAN handoff.

Subscriptions are bounded repository notifications identified by subscription ID and scoped to one authorized space. They are hints to fetch canonical state; they are not an authoritative state stream and are not persisted as application data.

## Failure and diagnostic rules

Unknown versions, malformed canonical data, unauthorized access, rollback, invalid causality, oversized state, and compaction mismatches return bounded reason codes. Diagnostics contain identifiers, versions, counts, and reason codes, but no values, attachment names, membership credentials, or private application state.
