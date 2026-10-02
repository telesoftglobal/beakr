# Lessons from the Current Prototype

This document records implementation-independent requirements learned from the existing Beakr prototype. It does not specify BeakrNet implementation details.

- A logical session must survive replacement of a transport connection.
- Duplicate message delivery must not repeat an operation.
- Peer identity must not depend on a Bonjour name, display name, or IP address.
- Loss of one interface must not revoke peer trust.
- Local Network permission denial must be distinguishable from route failure.
- Discovery must not imply authentication or authorization.
- Mobile applications must not be treated as permanently available servers.
- Peers may be on different LANs or may not be online simultaneously.
- Direct local delivery, relay delivery, and queued delivery require distinct capabilities.
- Shutdown, cancellation, and reconnection must produce observable deterministic state.

The existing `xyz` repository remains the authoritative source for the prototype and its historical design notes.
