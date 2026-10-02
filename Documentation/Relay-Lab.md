# Localhost Relay Lab

The relay lab proves that separate processes can register stable node identifiers and exchange framed BeakrNet envelopes through a central routing process.

## Current behavior

- TCP on localhost, port 7878 by default
- TLS 1.2 PSK transport encryption using AES-128-GCM with an explicit 32–64 byte development key
- Four-byte big-endian length prefix
- JSON-encoded development wire messages
- P-256 challenge-response authentication
- Node IDs derived from public keys
- Authority-signed node credentials with environment and expiry enforcement
- One active connection per authenticated Node ID
- In-memory queuing when a destination is disconnected
- Source Node ID checked against the connection registration

## Deliberate omissions

- Authority-issued credential validation
- Public certificate or production TLS identity
- Durable queued delivery
- Queue bounds and expiry
- Delivery acknowledgements across the relay wire
- Account ownership and authorization
- Internet deployment

The relay must remain localhost-only development infrastructure until authentication and transport security are implemented.
