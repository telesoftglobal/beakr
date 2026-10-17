# BeakrNet Functional Specification

## Network Authority

### Definition

The network authority is the trusted security service for one BeakrNet network. Each network has its own authority. The authority establishes the network's cryptographic identity and controls which node identities are permitted to participate.

The authority is software, not a person or an external Internet service. In the current architecture, it runs locally as an embedded service inside Beakr on the Mac that created the network.

### Creation and Ownership

Beakr creates the network authority automatically when a person selects **Create Network** on a supported creator device. The device on which that operation succeeds becomes the network creator and authority host.

The person supplies only a friendly network name, such as **Red**, **Blue**, or **ICE-9**. Beakr generates and configures the authority identity and operational parameters without requiring the person to enter identifiers, keys, certificates, hostnames, ports, or credential data.

Network creation generates:

- A unique internal Network ID.
- An authority signing key pair.
- A certificate-authority private key and certificate.
- An administrator credential for the creator device.
- An HTTPS server identity for the embedded authority service.
- Initial network-membership and revocation records.

The authority private keys remain in the creator device's Keychain and are never included in invitations. Possession of those keys is the basis for creator ownership. Only a device that possesses and can use the authority private material may perform creator operations for that network.

### Responsibilities

The network authority:

- Creates signed, time-limited, single-use invitations for joining devices.
- Verifies invitation use and proof of possession from a joining device.
- Issues network credentials and operational TLS certificates.
- Maintains authoritative membership and revocation state.
- Provides signed trust and revocation information to network members.
- Rejects expired, revoked, incorrectly signed, or wrong-network credentials.

Joined devices contact the authority over the local network when joining, enrolling or renewing certificates, and retrieving membership or revocation information.

### Creator-Only Management

Only the creator device may:

- Assign the network's friendly name during creation.
- List networks created and owned on that device.
- Create invitations for those networks.
- Delete an owned network and its local authority material.

A joined device receives network membership but does not receive the authority private keys or creator-management privileges.

## Certificate Enrollment

### Purpose

Certificate enrollment converts a device's existing Beakr identity into an operational identity for one BeakrNet network. Enrollment does not create the device identity or its private key. It authorizes that identity to establish mutually authenticated TLS connections within the selected network.

### Preconditions

Before enrollment begins:

- The device has a stable node identity and private key stored in Keychain.
- The device has an authority-issued node credential for the selected network.
- The device has the network authority's public signing key and certificate trust material.
- The authority control plane is reachable over HTTPS.

The network creator receives an administrator credential when the network is created. A joining device receives an ordinary network-membership credential through a valid, single-use invitation. Enrollment preserves those existing roles; it does not elevate privileges.

### Enrollment Flow

When the person selects **Enroll Certificate**, BeakrNet performs the following operations automatically:

1. Loads the device's existing node identity from Keychain. The private key never leaves the device.
2. Requests a one-time enrollment challenge from the network authority.
3. Signs the challenge locally with the node's private key, proving possession of that key.
4. Sends the signed proof and the authority-issued node credential to the network authority.
5. The authority verifies that:
   - The credential was issued by the expected authority.
   - The credential belongs to the selected network and environment.
   - The credential identifies the requesting node and its public key.
   - The request proves possession of the corresponding private key.
   - The credential is within its validity period.
   - The node has not been revoked.
6. The authority issues an operational TLS certificate bound to the node identity and network.
7. The device verifies the enrollment response and certificate against the configured authority.
8. The device stores the operational certificate and identity in Keychain.
9. The device downloads and verifies the current revocation state.
10. BeakrNet enables secure LAN routes only after the certificate and trusted revocation state are both available.

### Successful Outcome

After successful enrollment:

- The device can authenticate itself to other authorized nodes using mutual TLS.
- The device can validate peer certificates issued by the same network authority.
- Secure LAN routing can start.
- The user-facing state reports: **Identity, certificate, and revocation state are ready.**
- On the creator device, network-management operations such as creating device invitations become available.

### Failure Behavior

Enrollment fails closed. If challenge validation, credential verification, certificate issuance, certificate installation, or revocation recovery fails:

- Secure LAN routes remain disabled.
- Existing private keys are not exported or replaced.
- The network profile is not silently reassigned to another authority.
- The application reports that enrollment or revocation recovery failed and permits a later retry.

### Enrollment Does Not

Enrollment does not:

- Create another network.
- Change the network's friendly name.
- Generate or expose a human-entered Network ID or Node ID.
- Export a device private key.
- Transfer a private key through an invitation.
- Grant network-creator or administrator privileges to an ordinary joined device.
- Allow a joined device to list or delete networks owned by the creator device.

### Human Interaction

The person initiates enrollment as a single operation. BeakrNet must not require the person to enter Network IDs, Node IDs, authority hostnames, ports, certificates, private keys, credential JSON, or other enrollment parameters. Those values are generated, discovered, or supplied through trusted network-creation and invitation workflows.
