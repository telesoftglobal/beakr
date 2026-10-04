# Security Model

BeakrNet will authenticate stable node identities independently of network location and transport.

## Principles

- Private identity keys remain on their originating device.
- Bonjour advertisements and relay presence are untrusted discovery hints.
- A peer proves possession of the key associated with its credential.
- Authorization is scoped to an application service or operation, not merely to a device.
- Transport changes do not change the authenticated logical peer.
- Local operation must remain possible for a bounded period without Internet access.
- The experimental project must not read or reuse the current prototype's credentials.

Production hosting, authority-key custody, revocation fetch cadence, and offline grace policy remain deployment decisions.

## Development identity

The relay lab uses a P-256 signing key. A Node ID is derived from the SHA-256 digest of the public key. Registration requires the node to sign a fresh 32-byte server challenge over a domain-separated transcript. This demonstrates proof of private-key possession and prevents a connection from claiming an arbitrary Node ID.

Development private keys are stored as mode-0600 files by the CLI. Production Apple-platform clients should replace this with Keychain or Secure Enclave storage. Self-sovereign development identities do not establish account ownership, authorization, revocation, or issuer trust.

## Development relay TLS

The localhost relay uses TLS 1.2 PSK with AES-128-GCM and a 32–64 byte pre-shared key supplied from a mode-0600 development file. The TLS PSK protects confidentiality and authenticates membership in the development relay environment. The subsequent P-256 challenge-response authenticates the stable Node ID.

The PSK is not a production credential: every holder shares the same secret, individual holders cannot be revoked, and compromise affects the entire environment. A deployed relay should replace it with a conventional publicly trusted server certificate while retaining node-level credentials above TLS.

## Development credential authority

An independent P-256 authority signs versioned node credentials. Signed claims bind the credential ID, issuer, Node ID, node public key, environment, validity window, and sorted service scopes. The relay trusts an explicit authority public key and rejects credentials from other issuers, expired credentials, credentials for another environment, modified claims, and credentials whose key does not derive the claimed Node ID.

Credential signing uses an explicit length-prefixed binary transcript rather than serialized JSON bytes. JSON is only the file and wire representation. This avoids depending on encoder key order for signature verification.

The development authority uses mode-0600 key files. The package now defines a transport-neutral HTTPS enrollment handler and URLSession client, but deployment must provide the HTTP host, server authentication certificate, authority-key isolation, access logging, and request-rate controls.

## Revocation snapshots

The authority can issue a signed snapshot containing revoked credential IDs, timestamps, and reasons. The relay verifies the snapshot against its configured authority key at startup and rejects revoked credentials during registration. A malformed snapshot or one from another authority prevents relay startup.

Hosts persist snapshots atomically before publishing them. The distributor verifies authority signatures, rejects rollback and same-timestamp conflicts, updates every registered authenticated transport, and catches up transports registered later. A failed consumer is reported independently so it cannot prevent healthy routes from updating. LAN transports disconnect revoked peers, and relay clients close when their own configured credential is revoked. Fetch cadence and remote wakeup remain deployment control-plane responsibilities; an unsigned notification is never itself trusted as revocation state.

The refresh controller enforces verify-before-persist and persist-before-activate ordering. A corrupt, untrusted, rolled-back, or conflicting candidate cannot replace durable state; a storage failure cannot change the in-memory active snapshot. Startup re-verifies persisted state before distributing it. Scheduled and push-triggered refreshes share the same authenticated request boundary, retry policy, and diagnostics, so a push notification is only a hint to fetch authority-signed state.

The revocation endpoint exposes public, authority-signed state through an HTTPS-only conditional GET. URLSession performs normal server authentication, refuses redirects through the shared transport, and the refresh pipeline independently authenticates content with the pinned authority trust state. Responses require canonical encoding, the exact media type, bounded size, a matching strong generation ETag, and a strictly advancing generation unless the server returns `304`. No bearer token is used because confidentiality is unnecessary and possession of a shared retrieval secret would not authorize revocation state.

## Direct-LAN security gate

Bonjour discovery is attacker-controlled input. A service name, TXT Node ID, interface, address, and successful TCP connection establish no identity or authorization. Direct LAN becomes eligible only after a confidential channel and mutual node authentication complete.

The LAN proof must use a new domain-separated transcript binding roles, both fresh nonces, both Node IDs and credential IDs, the advertisement nonce, protocol version, negotiated capabilities, and both TLS leaf-certificate SHA-256 fingerprints. Both peers verify the authority credential, environment, validity, revocation state, Node-ID/public-key binding, LAN service scope, TLS-certificate key binding, and proof of the corresponding private key. Captured relay registration messages or LAN proofs from another connection must not verify.

The relay development PSK must not be reused as the LAN security design. The selected profile is mutual TLS 1.3 with one P-256 leaf certificate per node, followed by the signed application handshake for protocol identity, capabilities, and authorization. The certificate public key must exactly match the public key in the authority-signed node credential; a certificate key may not be an additional, indirectly delegated key.

Development nodes create a self-signed leaf from the same non-exportable node identity key and renew it every 30 days. Production enrollment returns an authority-issued leaf for that same key, valid for at most 30 days, with digital-signature key usage and BeakrNet's LAN client/server extended-key usages. Renewal replaces the certificate but not the Node ID or identity key. A lost or replaced identity key creates a new Node ID and requires new enrollment. Certificates and private keys remain in Keychain/Secure Enclave storage on Apple platforms.

Network-framework trust evaluation requires TLS 1.3, P-256, the expected key usages, and certificate validity. Bonjour service names are not DNS identities, so hostname validation is disabled. Development self-signed leaves are accepted only provisionally; production leaves must chain to the configured BeakrNet certificate authority. In both environments the connection remains ineligible and carries no application envelopes until the application handshake verifies the peer credential, exact leaf-key binding, certificate fingerprints in the signed transcript, LAN scope, and proof of possession. Any failure closes the connection.

Offline LAN authentication requires a valid authority revocation snapshot issued no more than 24 hours earlier. Missing, invalid, future-dated, rolled-back, or older snapshots fail closed for new LAN authentication. Installing a newer valid snapshot immediately closes an active LAN connection whose local or peer credential is revoked; route selection may then fall back to another independently authenticated route. Snapshot version and issue time are persisted to prevent rollback.

The initial authenticated LAN profile caps a complete encoded envelope at 1 MiB, including framing metadata. The frame decoder rejects the declared length before allocation, and capability negotiation uses the lower peer limit. Focused boundary tests are required before the Network adapter is enabled; later increases require measured peak-memory and framing tests on the oldest supported device.

## Current implementation boundary

The implemented LAN handshake enforces the authority credential, environment, validity, LAN scope, fresh signed revocation snapshot, Node-ID/key binding, role and nonce binding, replay prevention, negotiated capabilities, leaf-key equality, leaf fingerprints, and proof of possession before creating an eligible transport. Unit and handoff tests exercise rejection and route fallback behavior.

The opt-in macOS integration target establishes a real Network-framework TLS channel using the development relay PSK, then supplies deterministic peer-certificate metadata through the connection protocol seam. This validates Bonjour, TLS establishment, framing, and the complete application handshake without introducing keychain or code-signing state into SwiftPM tests.

The package-level PSK integration test does not by itself validate the selected production mutual-TLS profile; that responsibility belongs to the signed app-hosted suite using provisioned `SecIdentity` values.

`LANTLSConfiguration` now provides the shared Network-framework policy for that host. It requires TLS 1.3, installs a local `SecIdentity`, requires a peer certificate on both roles, and evaluates the peer with a role-sensitive SSL policy. Development provisionally anchors the presented self-signed leaf; production restricts trust to explicitly supplied authority certificates. In either mode, TLS readiness remains insufficient for route eligibility until the application handshake completes all credential, key-binding, fingerprint, revocation, and proof checks.

The signed-host mutual-TLS suite has now passed on macOS, iOS Simulator, and a physical iPhone using disposable authority-issued P-256 identities. It verifies successful encrypted connection establishment and rejection of the wrong authority, an expired leaf, and a missing client identity. Renewal scheduling uses the signed issuance window with bounded jitter, capped retry backoff, response re-verification, and install-before-activation semantics.

Authority rotation uses a predecessor-signed, environment-bound transition with a monotonic generation and bounded overlap deadline. During overlap, credential, revocation, and enrollment-response verification accepts the current and immediately previous authority; at the deadline the predecessor is removed. Replayed, skipped, tampered, wrong-environment, wrong-signer, future-dated, and expired transitions fail closed. A device that was offline for the entire overlap needs an explicit recovery or re-enrollment path; it does not silently trust a stale rotation statement.

Missed-window recovery requires a separately provisioned offline recovery public key and an explicitly applied recovery package. The recovery key must never be reused as an operational credential authority. Packages are environment-bound, valid for at most seven days, and must advance the persisted trust generation. Successful recovery replaces the current authority without preserving stale overlap trust. Recovery private-key custody, quorum or hardware-token policy, audit approval, and delivery are deployment responsibilities.

Enrollment uses two HTTPS POST endpoints. Challenges are random, short-lived, bounded in number, recorded by the issuing server, and consumed only after successful enrollment. Consequently, a node cannot manufacture a challenge locally even if it can produce a valid node signature. Requests and responses use canonical JSON with strict media type and size limits; responses are marked `no-store`. The client refuses non-HTTPS base URLs and checks challenge authority, environment, nonce size, and lifetime before signing. The deployment HTTP host remains responsible for publicly trusted TLS, redirect policy, denial-of-service controls, and keeping the credential and certificate authority signing keys out of the edge process where practical.
