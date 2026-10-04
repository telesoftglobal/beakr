# Reliable Large Data Transfer Design

Milestone 9 extends the Data protocol with bounded, resumable, store-and-forward transfers. It does not carry live audio or video samples.

## Boundary

The platform-neutral `BeakrNetTransfer` target depends on `BeakrNetData`, `BeakrNetControl`, and `BeakrNetCore`. It owns transfer wire schemas, staging contracts, integrity verification, progress, cancellation, and cleanup. Transports continue carrying opaque envelopes and never interpret chunks. Product code owns publication of a verified staged artifact.

## Identity and integrity

Each transfer has an immutable UUID-backed transfer ID. A versioned manifest commits to the total byte length, fixed chunk size, chunk count, SHA-256 content digest, media type, optional filename metadata, expiry, and source/destination/session context. Every chunk binds the transfer ID, zero-based index, byte offset, bytes, and a SHA-256 chunk digest. Final publication requires exact length, complete coverage without overlap, every chunk digest, and the manifest content digest.

Digest computation is injected behind a `TransferDigesting` boundary with a deterministic SHA-256 implementation. Tests may inject a deterministic verifier but cannot bypass length, index, or coverage validation.

## Resume and backpressure

The receiver reports a bounded sorted list of missing chunk ranges rather than an unbounded bitmap. Resume state is advisory: the manifest remains authoritative. Senders apply a bounded in-flight window and receiver-advertised retry delay. Control scheduling remains independent and retains its existing reserved capacity and bounded-burst fairness.

## Staging and publication

Incoming bytes are written only beneath an injected staging root using transfer-ID-derived names. A canonical atomic metadata snapshot records the manifest and received chunk indexes. Restart reconstructs staged work, rejects corrupt metadata, verifies existing chunk lengths and digests, and resumes only missing chunks. A completed artifact is atomically moved to a publication callback only after final digest verification.

No path, filename, or media-type field from the peer selects a filesystem location. Filenames are bounded display metadata only. Cancellation, expiry, failed integrity, and garbage collection remove staged bytes and metadata. Published application files are outside transfer garbage collection.

## Authorization and bounds

Authorization is checked after authenticated-session acceptance and before manifest admission, resume disclosure, chunk writes, cancellation, or publication. Policy bounds total and per-transfer staged bytes, concurrent transfers, chunk size/count, manifest metadata, missing ranges, in-flight chunks, expiry, and encoded payload size. Admission reserves the committed length before accepting chunks and fails without eviction of active work.

## Diagnostics

Diagnostics contain transfer ID, state, byte/chunk counts, and bounded reason codes. They exclude content bytes, digests, filenames, media types, filesystem paths, and authorization material.

## Completion criteria

Tests must cover canonical encoding, restart/resume, interruption, duplicate and conflicting chunks, corrupt chunks and final digest, bounds and storage pressure, expiry, cancellation cleanup, publication only after verification, unchanged identity across route handoff, and continued Control progress under sustained chunk traffic.
