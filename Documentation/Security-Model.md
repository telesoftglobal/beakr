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

Production credential formats, issuer operation, renewal, revocation, and offline grace policy remain intentionally undecided.

## Development identity

The relay lab uses a P-256 signing key. A Node ID is derived from the SHA-256 digest of the public key. Registration requires the node to sign a fresh 32-byte server challenge over a domain-separated transcript. This demonstrates proof of private-key possession and prevents a connection from claiming an arbitrary Node ID.

Development private keys are stored as mode-0600 files by the CLI. Production Apple-platform clients should replace this with Keychain or Secure Enclave storage. Self-sovereign development identities do not establish account ownership, authorization, revocation, or issuer trust.

## Development relay TLS

The localhost relay uses TLS 1.2 PSK with AES-128-GCM and a 32–64 byte pre-shared key supplied from a mode-0600 development file. The TLS PSK protects confidentiality and authenticates membership in the development relay environment. The subsequent P-256 challenge-response authenticates the stable Node ID.

The PSK is not a production credential: every holder shares the same secret, individual holders cannot be revoked, and compromise affects the entire environment. A deployed relay should replace it with a conventional publicly trusted server certificate while retaining node-level credentials above TLS.
