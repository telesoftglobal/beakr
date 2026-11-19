# Signing Authority Models and Recommendations

## Purpose

Beakr uses cryptographic credentials to decide which nodes may participate in a network. That security model must not require ordinary users to run command-line tools, move key files, understand certificate chains, or manually sign credentials.

This document describes how signing authority and device enrollment should appear in the product across common combinations of Apple devices. It also recommends an initial authority model for a usable first release.

## Product principle

The first trusted device creates the Beakr network and becomes its initial signing authority. Each later device generates its own identity and requests admission from an already authorized administrator.

Users should ordinarily encounter only these concepts:

- **Create Network**
- **Join Network**
- **Approve Device**
- **Remove Device**
- **Recovery**

Node identifiers, public keys, scopes, credentials, signatures, and revocation snapshots remain implementation details.

The existing `BeakrNetCredentialTool` remains useful for development, automation, recovery, and expert administration. It should not be part of the normal enrollment experience.

## Product packaging

For normal users, signing-authority capabilities should be integrated into the Beakr application rather than installed as a separate application.

Every Beakr installation can operate as an ordinary node. A Beakr installation may additionally hold an **Authority Administrator** role. Only installations explicitly holding that role may approve enrollment, issue or renew credentials, revoke devices, or administer recovery. Authority controls should be visible only when the local installation possesses the necessary authority.

Examples include:

- The first iPhone that selects **Create Network** becomes the initial authority.
- A joining iPhone receives an ordinary node credential unless it is explicitly promoted.
- A Mac that creates a network becomes the authority and exposes device-management controls.
- A Watch normally joins as a node and does not expose authority administration.
- A recovery device receives authority capability only through a deliberate, protected operation.

Although these functions are presented within one application, they must remain separated internally:

```text
Beakr application
├── Normal node functions
│   ├── Messaging
│   ├── Networking
│   └── Node credential use
│
└── Optional authority functions
    ├── Approve enrollment
    ├── Sign credentials
    ├── Renew credentials
    ├── Revoke devices
    └── Manage recovery
```

The signing implementation should live in a reusable library with a narrow authority interface. The Beakr application invokes that interface only when the local installation is an authorized administrator. Authority key material remains protected by the device's Keychain or suitable hardware-backed storage and must not become accessible to ordinary node functions.

A separate authority application may still be appropriate for an organization operating a dedicated administrative Mac. That is an optional deployment model, not a requirement for individuals, households, or other small trusted groups.

The recommended platform presentation is therefore:

| Platform | Authority presentation |
| --- | --- |
| iPhone | Integrated into Beakr when the iPhone is an administrator |
| Mac | Integrated into Beakr, with an optional dedicated authority mode or future administrative application |
| Apple Watch | Primarily a node; authority operation is limited to Watch-only bootstrap or carefully designed recovery |
| Command line | `BeakrNetCredentialTool` for development, automation, controlled provisioning, and expert recovery |

## Trust boundaries

Each Beakr device must generate and retain its own private identity key. Enrollment may exchange public keys, short-lived invitations, signed credentials, and revocation information, but it must never transfer or duplicate a device's private identity key.

The network-authority signing key is separate from every device identity key. Possession of a node credential permits only the capabilities granted to that node; it does not automatically confer authority to enroll other devices.

An existing Apple relationship, such as an iPhone paired with a Watch or devices using the same Apple Account, may simplify discovery and confirmation. It must not silently grant Beakr authorization.

## Enrollment by device configuration

### Only an iPhone

1. The user selects **Create a Beakr Network**.
2. The iPhone generates a device identity key.
3. It generates a separate network-authority signing key.
4. It issues its own initial authority-signed node credential.
5. Private material is stored using the strongest suitable Keychain and hardware-backed protection available.

The iPhone acts both as a normal Beakr node and as the initial enrollment authority. No Terminal commands or manual credential files are exposed.

Because this is the only authority, setup must also establish recovery. Beakr should offer an encrypted recovery package or recovery code and clearly explain the consequence of losing both the device and its recovery material.

### Only an Apple Watch

1. The user selects **Create Network** on the Watch.
2. The Watch generates its identity and an initial network authority.
3. It issues its own initial credential and stores the keys locally.
4. It offers a minimal recovery setup appropriate to the Watch interface.

Watch-only operation is possible in principle, but it has significant usability and recovery constraints. Authority administration is difficult on a small display, and safe backup or export requires careful design.

The Watch-only experience should support basic operation while encouraging the user to add an iPhone or Mac as a recovery administrator. If safe recovery has not been configured, the product must state plainly that loss of the Watch may make the network unrecoverable.

### An iPhone and an Apple Watch

The iPhone should normally establish the network and approve the Watch:

1. The Watch selects **Join Existing Network** and creates its own private identity key.
2. The Watch sends an enrollment request containing its public identity.
3. The iPhone displays the requesting Watch and a matching visual or short verification code.
4. The user confirms **Approve Watch**.
5. The authority issues and returns a Watch-specific credential.
6. The Watch validates and stores the credential locally.

The Watch must not copy or reuse the iPhone's private identity key. Its paired relationship may simplify transport and device identification, but explicit Beakr approval is still required.

### Several iPhones

The first iPhone creates the network. Each additional iPhone joins independently:

1. The existing iPhone selects **Add Device**.
2. The new iPhone selects **Join Network**.
3. The devices connect using a short-lived QR invitation or authenticated nearby discovery.
4. Both devices present matching identity information or a short verification code.
5. The existing administrator approves the request.
6. The new iPhone receives its own signed credential.

Approval should distinguish between roles. A new iPhone may be:

- A normal participant.
- An administrator allowed to approve or revoke devices.
- A recovery authority.

Joining the network must not automatically grant signing authority.

### Only a Mac

1. The user selects **Create a Beakr Network** in a normal Beakr interface.
2. The Mac generates its node identity and a separate authority key.
3. The Mac issues its own initial node credential.
4. Sensitive signing operations are protected by macOS authentication, such as administrator authorization or Touch ID where available.

A Mac is well suited to be a persistent authority because it can remain available for enrollment, maintain revocation state, present a complete administration interface, and apply stronger operational controls.

The command-line credential tool remains an administrative fallback, not the primary product interface.

### A Mac and one or more iPhones

The Mac should normally act as the primary authority:

1. The Mac selects **Add Device** and displays a short-lived enrollment invitation as a QR code.
2. The iPhone scans the invitation and generates its identity locally.
3. The iPhone submits its public enrollment request over the authenticated invitation channel.
4. The Mac displays the requesting device and asks an administrator to approve it.
5. The Mac issues a credential bound to that iPhone's identity.
6. The iPhone validates and stores the credential.
7. The process repeats independently for each additional device.

The QR code must contain only a short-lived, single-purpose invitation. It must not contain the authority private key or a reusable node credential.

One or more iPhones may later be designated as recovery administrators through a separate, explicit operation protected by user authentication.

## Configuration summary

| Available devices | Initial authority | Enrollment approach |
| --- | --- | --- |
| iPhone only | The iPhone | Automatic first-device bootstrap |
| Watch only | The Watch | Automatic bootstrap with explicit recovery limitations |
| iPhone and Watch | The iPhone | Nearby request and explicit approval |
| Several iPhones | The first iPhone | Short-lived QR or nearby invitation and approval |
| Mac only | The Mac | Automatic first-device bootstrap |
| Mac and iPhones | The Mac | Short-lived QR invitation and Mac approval |

## Authority model alternatives

### Single authority

Exactly one device holds the network signing authority.

This is simple to implement and understand, but loss or failure of that device can block enrollment and revocation unless a reliable recovery mechanism exists.

### Replicated authorities

Selected administrator devices each possess authority capable of signing credentials.

This improves availability, but it increases the number of places from which the network can be compromised. Replication, removal, rotation, and conflict handling must be carefully defined.

### Threshold authority

Authority is divided so that a minimum number of approved devices must cooperate to sign sensitive changes.

This can provide strong compromise resistance and recovery properties, but it introduces substantial protocol, user-interface, synchronization, and support complexity.

## Initial recommendation

For Beakr's first usable release, use:

- One primary signing authority.
- A separately protected encrypted recovery mechanism.
- Explicitly designated backup or recovery administrators.
- Per-device identity keys and credentials.
- Short-lived, single-use enrollment invitations.
- Explicit user confirmation before admitting or promoting a device.
- Simple **Remove Device** behavior backed by the existing revocation system.
- Automatic credential renewal that does not require routine user intervention.

This model preserves the current authenticated protocol and credential architecture while providing an enrollment experience suitable for normal users. Threshold signing should be considered only after real deployment experience demonstrates a need that outweighs its complexity.

## Required product behavior

The product-level enrollment implementation should ensure that:

- Capability and protocol negotiation remain authoritative in the authenticated handshake.
- Route discovery and proximity are advisory and never authorize enrollment by themselves.
- Enrollment invitations expire quickly, are bounded, and cannot be replayed.
- Device identity, displayed verification information, and issued credential are cryptographically bound.
- Authority operations require appropriate local user authentication.
- Removal and revocation propagate through the established authenticated mechanisms.
- Diagnostic output never exposes private keys, invitation secrets, or reusable credentials.
- Losing an administrator device does not silently weaken security or promote another node.

## Operational role of `BeakrNetCredentialTool`

The credential tool should continue to exist on trusted administrative systems for:

- Development and integration testing.
- Initial provisioning in controlled deployments.
- Automated authority workflows.
- Disaster recovery and forensic inspection.
- Expert or headless administration.

In a production consumer workflow, a Beakr authority service or administrative interface should invoke the same underlying authority library. Ordinary users should not need to execute the tool or directly handle its cryptographic artifacts.

## Impact on the current Beakr projects

This authority model changes the product-facing enrollment direction, but it does not invalidate the existing BeakrNet security implementation.

The current Beakr application exposes a development provisioning workflow. A user manually provides a control-plane URL, authority public key, and credential JSON. This is useful for development and integration testing, but it should eventually be replaced in the production application by **Create Network** and **Join Network** workflows.

### Components that remain

- `BeakrNetAuthority` remains the reusable signing and authority library.
- `BeakrNetSecurity` continues to own identity, Keychain, handshake, and TLS security behavior.
- `BeakrNetCredentialTool` remains a command-line administration, automation, and recovery utility.
- Existing authentication, credential validation, revocation, renewal, and route restrictions remain unchanged.
- No separate consumer authority Xcode project is required.
- `BeakrNetDemo` remains a development and integration environment rather than the intended enrollment experience.

The current package boundaries are broadly compatible with the proposed authority model.

### Beakr application changes

The current development configuration interface should eventually be replaced with an enrollment state model similar to:

```text
Unconfigured
├── Create Network
│   └── Initial authority administrator
└── Join Network
    ├── Scan invitation
    ├── Verify existing administrator
    ├── Await approval
    └── Install credential

Configured
├── Normal member
└── Authority administrator
    ├── Add Device
    ├── Pending Requests
    ├── Remove Device
    └── Recovery
```

Normal users should no longer be asked to paste an HTTPS control-plane URL, authority public key, or credential JSON. Those controls may remain available behind a development-only interface for controlled testing.

### Proposed enrollment library

A new platform-neutral `BeakrNetEnrollment` library should coordinate enrollment without duplicating the existing cryptographic implementation. Its domain could include:

```text
BeakrNetEnrollment
├── EnrollmentInvitation
├── EnrollmentRequest
├── EnrollmentApproval
├── EnrollmentCoordinator
├── AuthorityRole
├── DeviceRecord
└── EnrollmentPolicy
```

Its responsibilities should include:

- Short-lived, single-use invitations.
- Public-key enrollment requests.
- Explicit approval and rejection.
- Credential-issuance orchestration through `BeakrNetAuthority`.
- Administrator-role assignment.
- Replay prevention and resource bounds.
- Recovery-administrator enrollment.

The portable protocol layer should use the existing `BeakrNetCore`, `BeakrNetSecurity`, and `BeakrNetAuthority` facilities. Apple-specific concerns remain outside that portable layer, including:

- QR-code scanning and presentation.
- Keychain access.
- Touch ID or Face ID authorization.
- Nearby transport selection.
- Application lifecycle and user interface.

### Separate authority-key storage

The application already stores its node identity and node credential securely, but product authority-key ownership requires an additional store with a distinct purpose and access policy:

```text
Node identity store
└── Authenticates this device as a Beakr node

Authority key store
└── Approves, signs, renews, revokes, or recovers authority state
```

Possessing a normal Beakr node credential must never make authority signing operations available. Authority operations should require the explicit administrator role and appropriate local user authorization.

### Project-level effects

| Project or target | Recommended effect |
| --- | --- |
| `BeakrNet` package | Add enrollment protocol and coordinator functionality with deterministic tests |
| `Beakr` application | Replace manual provisioning with Create, Join, and Administration experiences |
| `BeakrNetDemo` | Retain manual configuration for development and integration testing |
| `BeakrNetCredentialTool` | Retain as an expert administrative and recovery utility |
| Mac application | Use the same Beakr application with authority administration enabled by role |
| Watch application | Add later; operate primarily as a joining node with limited bootstrap support |
| Separate authority application | Do not create now; reconsider only for organizational deployments |

### Recommended implementation sequence

The next safe implementation slice is the platform-neutral enrollment protocol rather than the user interface:

1. Define bounded invitation, request, approval, rejection, and role types.
2. Add invitation expiry, single-use enforcement, and replay protection.
3. Bind every enrollment request to the requesting node's public key and Node ID.
4. Add an authority coordinator that delegates signing to `BeakrNetAuthority`.
5. Add deterministic package tests for validation, authorization, expiry, replay, and resource bounds.
6. Integrate **Create Network** and **Join Network** into the Beakr application.
7. Add Apple-specific QR, proximity, Keychain, and local-authentication adapters only after the protocol behavior is established.

No existing code or project configuration needs to be deleted before this work begins. The development provisioning path can remain available until the production enrollment workflow has equivalent test and operational coverage.

## First implementation milestone: initial node bootstrap and enrollment

Secure initial operation is foundational. Transport becomes useful only after a node knows its identity, the network to which it belongs, and whether it is authorized. The first implementation should establish one complete, testable bootstrap path:

> One device creates a network; a second device requests admission; the first approves it; both subsequently restore their state without manual configuration.

### First-release decisions

The first implementation should adopt these explicit rules:

- One primary signing authority exists per network.
- The first device creates that authority.
- Every device has a separate node identity.
- Joining a network does not confer administrator authority.
- Enrollment invitations are short-lived and single-use.
- Initial product coverage includes iPhone and Mac.
- Watch-only bootstrap and authority replication are deferred.
- The existing manual development configuration remains available as a fallback.

These constraints keep the initial implementation focused and avoid prematurely creating a distributed-authority system.

### Release 1 lifecycle-record and authority-policy design

For Release 1, the lifecycle record is a compact durable checkpoint and authority policy is immutable injected configuration. The record stores facts required to resume safely. The coordinator derives user-visible state from those facts together with current Keychain availability and trust validation.

The lifecycle record contains a format version, monotonic revision, installation identifier, durable phase, node identifier when one exists, public network binding, pending-enrollment reference, local-authority reference when present, and creation and update timestamps. Its durable phases are `unconfigured`, `identityReady`, `joining`, `installingMembership`, `member`, `leaving`, and `recoveryRequired`.

The public network binding records the Network ID, display name, environment, pinned Authority ID and public key, active credential ID, membership and revocation generations, and optional control-plane URL. A pending enrollment records the invitation and request identifiers, expected network and authority, local Node ID, expiration and creation times, bounded retry metadata, and request status. The invitation secret must be removed after acceptance or consumption. A local-authority binding records the Authority ID, authority role, a persistent reference to authority-key material rather than private-key bytes, and the applicable authority, membership, and revocation generations.

The lifecycle record must not embed node or authority private keys, complete credentials or certificates, revocation snapshots, consumed-invitation history, enrolled-device collections, transient user-interface state, or derived health such as credential expiry. Those values remain in their existing secure or bounded stores.

Persisted phase is a recovery checkpoint rather than proof that an installation is usable. Startup derives node and authority lifecycle state from the record plus node-key availability, credential verification, trust-ledger verification, revocation freshness, certificate availability, authority-key availability, and pending-transaction recovery. For example, a persisted `member` record may derive `ready`, `locked`, `credentialExpired`, `credentialRevoked`, `trustStateStale`, `certificateRecoveryRequired`, or `recoveryRequired` as current conditions require.

Every mutation uses a staged transaction:

1. Validate the current revision and permitted transition.
2. Generate or verify all cryptographic artifacts.
3. Stage secure material and public records.
4. Commit the lifecycle record last.
5. Activate networking only after reloading and validating the committed record.

Creation and enrollment retain explicit intermediate phases because they touch multiple stores. On restart, `joining` resumes or safely expires its pending request, `installingMembership` completes installation or rolls back staged artifacts, and `leaving` finishes deterministic cleanup. An impossible combination becomes `recoveryRequired`. Missing state never causes automatic identity or authority regeneration. The monotonic revision protects against overlapping user-interface, background, and renewal operations.

Release 1 authority policy defines credential, certificate, invitation, and pending-request validity; allowed clock skew; limits for invitations, requests, devices, and payload bytes; the default and permitted device roles; and local-authorization requirements for approval and revocation. Policy construction rejects invalid or unbounded values.

The governing policy is:

- Exactly one operational authority exists.
- Joined devices receive the ordinary member role; invitation input cannot request administrator authority.
- Only network creation may establish the initial administrator.
- Promotion, authority replication, and threshold authorization are deferred.
- Approval and revocation require an injected local-authorization grant.
- Credential scopes come from policy rather than untrusted request fields.
- Invitation consumption and credential issuance form one authority transaction.
- Rejection does not consume an invitation unless the request is identified as abusive.
- Revocation is permanent for a credential ID; rejoining requires a fresh invitation and credential.
- Resource limits are mandatory and have no unbounded defaults.

`AuthorityRole` is omitted from the Release 1 enrollment request. A joining node has no legitimate reason to select it. Authority capability is local administrative state backed by possession of the separately protected authority key, not a role granted through ordinary enrollment.

This design wraps rather than replaces existing authority behavior. `CredentialAuthority` remains responsible for credential signatures, `NetworkInvitation` remains the signed invitation representation, `ProfileMembershipSnapshot` remains published membership state, and revocation snapshots remain authoritative for removal. `NetworkBootstrap` should eventually be decomposed behind the coordinator because its current result exposes authority private-key bytes and is therefore unsuitable as the application-facing Release 1 boundary. `ProfileMembershipRecord` is not reused as the lifecycle record because it describes published session membership rather than local installation recovery or administrator authorization.

The first implementation slice consists of lifecycle types, policy validation, deterministic state derivation, transition validation, and in-memory test stores. Enrollment wire messages and application UI follow only after this crash-recovery boundary is established.

### Node lifecycle

The application should replace its coarse bootstrap states with an explicit lifecycle owned by platform-neutral logic:

```text
Starting
├── No local identity
│   └── Create identity
├── Identity without network membership
│   ├── Create Network
│   └── Join Network
├── Enrollment pending
├── Credential installed
│   └── Recover certificate and revocation state
├── Ready
├── Credential expired or revoked
└── Recovery required
```

An authority installation additionally needs these states:

```text
Authority unavailable
Authority locked
Authority ready
Authority recovery required
```

The state machine must be deterministic and independently testable. Application UI displays the resulting state but does not define protocol transitions.

### `BeakrNetEnrollment` targets

Add a new Swift package library and a separate test target:

```text
BeakrNetEnrollment
BeakrNetEnrollmentTests
```

The initial library should depend only on the existing components that enrollment genuinely requires:

- `BeakrNetCore`
- `BeakrNetSecurity`
- `BeakrNetAuthority`

Initial domain types should include:

- `NetworkID`
- `EnrollmentInvitation`
- `EnrollmentRequest`
- `EnrollmentDecision`
- `EnrollmentApproval`
- `EnrollmentRejection`
- `DeviceRole`
- `AuthorityRole`
- `EnrolledDevice`
- `EnrollmentPolicy`

Every wire payload requires a strict discriminator, an independent version, canonical encoding, and explicit size and collection bounds.

### First-network creation

Implement a platform-neutral coordinator operation conceptually equivalent to:

```swift
createNetwork(nodeIdentity:) -> InitialNetworkState
```

It should:

1. Accept an already-created node identity.
2. Generate a distinct authority identity.
3. Create a new network identifier.
4. Issue the first node credential.
5. Assign the creating node the administrator role.
6. Produce persistable network and authority state.

Creation must be atomic. If persistence fails partway through, the installation must not appear successfully configured.

The portable coordinator must not depend on SwiftUI, QR codes, Keychain, or a concrete network transport.

### Two-device enrollment exchange

The first vertical slice should use an in-memory transport in package tests:

```text
Authority device                 Joining device
      │                                │
      ├──── short-lived invitation ───>│
      │                                ├─ generates identity locally
      │<──── enrollment request ───────┤
      ├─ validates and approves        │
      ├──── signed approval ──────────>│
      │                                ├─ verifies and installs credential
      │<──── confirmation ─────────────┤
```

The exchange must cryptographically bind:

- Network ID.
- Invitation ID.
- Authority identity.
- Joining Node ID.
- Joining public key.
- Requested role.
- Expiration time.
- Nonce or equivalent replay protection.
- Issued credential.

An invitation authorizes only an enrollment attempt. It never constitutes network membership.

The Release 1 wire contract uses five independently versioned, canonically encoded messages: `EnrollmentInvitation`, `EnrollmentRequest`, `EnrollmentApproval`, `EnrollmentRejection`, and `EnrollmentConfirmation`. Each message has a strict type discriminator and a domain-separated signature. The invitation is authority-signed and carries a 32-byte one-time secret. The request embeds that invitation and binds a fresh request ID and 32-byte nonce to the joining Node ID, public key, and ordinary member role with the joining node's signature. Authority decisions bind the invitation, request, nonce, network, authority, and node. An approval additionally binds the issued credential and signed membership and revocation snapshots. The joining node's confirmation binds the approval, request, credential, network, and node before the authority treats the exchange as completed.

Complete encoded payloads are capped at 256 KiB. Decoding rejects malformed, oversized, noncanonical, unknown-type, and unknown-version payloads before they reach coordinator state. The initial request schema permits only the ordinary member role; it contains no authority-administrator request field.

The authority coordinator keeps bounded invitation and pending-request state. Re-submitting the identical signed request is idempotent; reusing its request ID with different content, submitting a second request for the same invitation, or submitting after the invitation is consumed fails explicitly. Approval requires an injected, fresh local-authorization grant bound to the request ID. The coordinator stages the next signed membership generation before atomically recording the approval decision and consuming the invitation. Membership activation then precedes finalization of the decision. If activation is interrupted, the exact signed approval and transaction remain recoverable; restart resumes publication without issuing another credential or advancing membership twice.

The joining coordinator verifies the imported invitation before persisting the exact signed request and entering `joining`. A verified approval is staged before the lifecycle advances to an `installingMembership` transaction. Credential and trust activation occurs before the final `member` checkpoint, after which the joining node emits a signed confirmation. If activation or the final checkpoint is interrupted, restart resumes from the staged approval without generating another request, identity, credential, or network binding. A verified rejection returns to `identityReady` while preserving the existing node identity and removing the pending request.

### Security and resource bounds

Package tests must cover at least:

- Expired invitations.
- Reused invitations.
- Unknown payload versions.
- Node ID and public-key mismatch.
- Wrong network or authority.
- Modified requests and approvals.
- Unauthorized administrator-role requests.
- Excessive payload sizes.
- Excessive pending requests.
- Duplicate requests.
- Approval replay.
- Credential expiry or revocation during enrollment.
- Clock-boundary behavior using an injected deterministic clock.

Structured diagnostics must identify the failure category without exposing private keys, invitation secrets, or complete credentials.

### Persistence contracts

Portable enrollment logic should depend on narrow storage protocols such as:

```swift
protocol NodeStateStore
protocol AuthorityStateStore
protocol EnrollmentReplayStore
protocol EnrolledDeviceStore
```

Apple-platform implementations should store:

- Node identity in the existing Keychain-backed identity store.
- Node credentials in Keychain.
- Authority keys in a separate and more restricted Keychain namespace.
- Public device records in application storage.
- Consumed invitations and replay state in bounded persistent storage.

Authority-key access must remain distinct from routine node-key access and should support requiring local user authorization.

The portable Release 1 stores persist lifecycle, authority-enrollment, joining-enrollment, and membership-publication state as independently versioned canonical snapshots with a 4 MiB hard limit and atomic file replacement. Loading rejects malformed, oversized, noncanonical, duplicate, cross-referenced, or unsupported snapshots. Mutations update in-memory state only when the durable replacement succeeds. Staged and activated transaction identifiers remain persisted so reactivation is idempotent after process termination.

These files contain protocol state, including pending invitations and requests, and must reside in an application-protected container with the platform's strongest appropriate data-protection class. They are not substitutes for Keychain storage: node and authority private keys remain behind the dedicated secure-store contracts. Diagnostics and backups must treat pending enrollment snapshots as sensitive because an unexpired invitation contains bearer material.

Cold start maps only durable facts to an action: show unconfigured state, restore identity, wait for the exact pending request, resume network creation, resume joining installation, start the member runtime, finish leaving, or require recovery. Missing or inconsistent transaction information selects recovery rather than guessing or regenerating identity material.

#### Durable enrollment implementation status

The Release 1 durable enrollment layer is implemented in `BeakrNetEnrollment`:

- `EnrollmentPersistence.swift` provides canonical JSON snapshots, a 4 MiB hard limit, atomic replacement, the persistent lifecycle store, and deterministic cold-start actions.
- `PersistentAuthorityEnrollmentStateStore.swift` persists invitations, requests, invitation consumption, pending approvals, and completed decisions.
- `PersistentJoiningEnrollmentStore.swift` persists exact joining requests, staged approvals, and activated approval transactions.
- `PersistentAuthorityMembershipPublisher.swift` persists staged membership generations and idempotent activation markers for restart-safe publication.

Cold start now deterministically selects unconfigured setup, identity restoration, waiting for an administrator, network-creation recovery, joining-installation recovery, member-runtime startup, leave completion, or explicit recovery.

The enrollment test suite contains 34 tests across eight suites. Coverage includes store recreation, corrupt and noncanonical snapshots, oversized files, transaction recovery, and idempotent activation. The Xcode workspace builds successfully with this implementation, and repository diff validation reports no whitespace errors.

### Cold-start restoration

Before enrollment UI is added, startup must reliably:

1. Restore or create the node identity.
2. Determine whether network membership exists.
3. Restore the authority role when present.
4. Validate the stored node credential.
5. Restore trusted revocation state.
6. Renew certificates when necessary.
7. Enable routes only after the required trust state is ready.

A failure must transition to a recoverable state. It must never silently create a replacement identity or a second network.

### Minimal application integration

After deterministic package tests pass, replace the manual production entry screen with:

```text
Welcome to Beakr

[ Create Network ]
[ Join Network ]
```

The first application slice needs only:

- Create-network confirmation.
- Invitation presentation as text or encoded data.
- Invitation import or paste on the joining device.
- A pending-request list.
- Approve and reject controls.
- Enrollment-complete status.

QR scanning and nearby discovery should follow later. Beginning with copyable encoded invitations validates the enrollment protocol without making camera and discovery behavior part of the initial debugging surface.

The current configuration form should remain accessible through an explicitly labelled development mode until the production workflow has equivalent coverage.

### Apple-platform validation

After the in-memory flow is deterministic, signed Apple-platform tests should verify:

- Keychain persistence across application restart.
- First-network creation on an iPhone.
- Enrollment between a Mac and an iPhone.
- Credential restoration after process termination and device restart.
- Revoking or removing a device prevents reconnection.
- A normal member cannot approve another device.

### Milestone definition

The next milestone should be defined as:

> **Initial Node Bootstrap and Enrollment:** Implement deterministic first-network creation and one-authority/one-joining-node enrollment in `BeakrNetEnrollment`, including canonical payloads, persistence contracts, expiry, replay prevention, credential issuance, role enforcement, and complete package tests.

This milestone stops before QR scanning, nearby discovery, polished UI, Watch enrollment, replicated authorities, threshold signing, and cloud recovery.

The completion criterion is that two newly created in-memory nodes can establish a network, enroll securely, restart from persisted state, communicate through the existing authenticated session stack, and reject replayed or unauthorized enrollment attempts.

## Xcode workspace and project changes

The workspace requires only a small structural change. Most implementation belongs in the existing BeakrNet Swift package and Beakr application. No new workspace or consumer application project is required.

The intended structure is:

```text
Beakr.xcworkspace
├── BeakrNetDemo.xcodeproj
├── Beakr.xcodeproj
└── Packages
    └── BeakrNet
        ├── BeakrNetEnrollment
        └── BeakrNetEnrollmentTests
```

The local `BeakrNet` package is already attached to the workspace. New package targets should therefore appear under **Package Dependencies → BeakrNet** after package resolution.

### Swift package manifest

Add a library product to `Package.swift`:

```swift
.library(
    name: "BeakrNetEnrollment",
    targets: ["BeakrNetEnrollment"]
)
```

Add its implementation target:

```swift
.target(
    name: "BeakrNetEnrollment",
    dependencies: [
        "BeakrNetCore",
        "BeakrNetSecurity",
        "BeakrNetAuthority"
    ]
)
```

Add a separate test target:

```swift
.testTarget(
    name: "BeakrNetEnrollmentTests",
    dependencies: [
        "BeakrNetEnrollment",
        "BeakrNetCore",
        "BeakrNetSecurity",
        "BeakrNetAuthority",
        "BeakrNetTestSupport"
    ]
)
```

Add these filesystem directories:

```text
Packages/BeakrNet/Sources/BeakrNetEnrollment/
Packages/BeakrNet/Tests/BeakrNetEnrollmentTests/
```

Swift Package Manager discovers source files in these directories automatically. Individual package files do not require manual Xcode project references.

### Beakr application target

The existing **Beakr** application target must link the `BeakrNetEnrollment` package product. This should be configured through Xcode:

1. Select the blue **Beakr** project.
2. Select the **Beakr** application target.
3. Open **General**.
4. Under **Frameworks, Libraries, and Embedded Content**, click `+`.
5. Select **BeakrNetEnrollment**.
6. Use **Do Not Embed** if Xcode presents an embedding option for the static Swift package product.

The product may also be shown under **Build Phases → Link Binary With Libraries**. Project files should be changed through Xcode rather than by directly editing `.pbxproj` content while Xcode is open.

Application source may then import the library with:

```swift
import BeakrNetEnrollment
```

### Beakr source organization

Application-specific enrollment code should remain in the existing Beakr target and use a filesystem layout matching its Xcode navigator organization:

```text
Beakr
└── Beakr
    ├── Enrollment
    │   ├── EnrollmentFlowModel.swift
    │   ├── NetworkCreationView.swift
    │   ├── NetworkJoinView.swift
    │   ├── PendingEnrollmentsView.swift
    │   └── AuthorityAdministrationView.swift
    ├── NodeBootstrapModel.swift
    └── ContentView.swift
```

These application files belong only to the existing Beakr application target. They do not require another application target.

### Application tests

Portable enrollment protocol behavior belongs in `BeakrNetEnrollmentTests`.

The existing `BeakrTests` target should cover application integration such as:

- Mapping enrollment states into displayed application states.
- Create-versus-join navigation.
- Hiding authority controls from ordinary members.
- Restoring application state.
- Preserving development-mode fallback behavior.

Tests using `@testable import Beakr` generally do not need a direct package dependency. If an application test imports `BeakrNetEnrollment` directly, link that package product to the `BeakrTests` target through Xcode.

UI tests should be added after the enrollment screens and accessibility identifiers are stable.

### Test plans and schemes

Swift Package Manager exposes `BeakrNetEnrollmentTests` when the package is opened directly or run from the package directory:

```bash
cd /Users/ice-9/Documents/_Projects/Beakr/Packages/BeakrNet
swift test --disable-sandbox
```

Package test targets may not appear in a test plan owned by the enclosing Beakr workspace. Therefore:

- Keep portable tests in the Swift package.
- Run them with `swift test` or from a package-only Xcode window.
- Keep `BeakrTests` and `BeakrUITests` in the Beakr project's test plan.
- Do not create an empty workspace test plan merely to represent package tests.

No manually shared scheme is initially required for `BeakrNetEnrollment`.

### Entitlements and capabilities

The platform-neutral enrollment milestone should not initially require new application capabilities:

- Standard application-local Keychain storage does not require Keychain Sharing.
- Camera permission is unnecessary until QR scanning is implemented.
- Copyable invitation testing does not require new Bonjour service declarations.
- No App Group is required.
- No iCloud Keychain or CloudKit capability is required.
- No Watch application target is required yet.

When QR scanning is later introduced, the Beakr application will require the appropriate camera usage description. Keychain Access Groups should be considered only if authority material must later be shared between separate signed applications.

### BeakrNetDemo

`BeakrNetDemo.xcodeproj` requires no initial change. Its manual credential and integration workflow should remain intact while the production enrollment system is developed.

The demo may later link `BeakrNetEnrollment` to exercise failure and adversarial scenarios, but that is not required for the first product integration.

### Dependency direction during migration

The Beakr application currently imports lower-level authority functionality for development bootstrap. That may remain during migration. The intended production dependency direction is:

```text
Beakr application
    → BeakrNetEnrollment
        → BeakrNetAuthority
        → BeakrNetSecurity
        → BeakrNetCore
```

Production application code should not directly construct credentials or manipulate authority signing keys. Existing direct use may remain behind a clearly development-only boundary until migration is complete.

### Minimal required Xcode changes

The initial milestone requires only:

1. Add `BeakrNetEnrollment` and `BeakrNetEnrollmentTests` to `Package.swift`.
2. Add their `Sources` and `Tests` directories.
3. Resolve the package changes in Xcode.
4. Link `BeakrNetEnrollment` to the existing Beakr application target.
5. Add enrollment application files to the existing Beakr target.
6. Add application integration tests to `BeakrTests`.
7. Keep package tests outside the workspace-owned test plan.

No new workspace, Xcode project, consumer application target, Watch target, entitlement, or separate authority application is needed for the first milestone.

## Decision: no separate authority application is currently required

There is no requirement today for a separate authority application. Any Beakr node may potentially hold an additional **Authority Administrator** role, so the existing Beakr application can operate as:

- An ordinary node only.
- The primary signing authority.
- An explicitly approved backup or recovery administrator.

This does not mean that every node is automatically authoritative. Authority is an additional capability backed by separate authority key material, an explicit role assignment, and appropriate local authorization.

```text
Ordinary Beakr node
├── Node identity
├── Node credential
└── Normal network capabilities

Authority-enabled Beakr node
├── Everything available to an ordinary node
├── Authority Administrator role
├── Separately protected authority key
└── Enrollment, renewal, revocation, and recovery controls
```

The architecture must distinguish between a separate application and a separate security component:

- A separate consumer authority application is not currently needed.
- Separate internal authority logic, key storage, authorization policy, and user-interface boundaries are required.

`BeakrNetAuthority` provides the existing authority-library boundary. The proposed `BeakrNetEnrollment` library should control when and how an authorized Beakr installation may invoke authority operations.

`BeakrNetCredentialTool` remains a development, automation, controlled-provisioning, and recovery utility. It is not a separate consumer application.

A dedicated authority application may become useful later for centrally administered organizations, dedicated administrator Macs, formal audit requirements, or hardware-backed signing infrastructure. It is unnecessary for the initial personal and small-group deployment model.

## Authority discovery and offline behavior

A joining device must not search for whichever node claims to be authoritative. That would allow an attacker or accidentally reset installation to impersonate an authority.

The first installation becomes authoritative only for the particular Beakr network it creates. Other devices learn the expected authority identity through a trusted, short-lived invitation.

### Finding the authority

When a first device creates a network, it generates:

- A network identifier.
- An authority signing identity.
- Its own node identity.
- Its initial administrator credential.

When the authority selects **Add Device**, it creates an invitation containing information conceptually equivalent to:

```text
Network ID
Authority public-key fingerprint
Invitation ID
Expiration
One-time enrollment secret
Available rendezvous methods
Authority signature
```

The invitation may be transferred through:

- Copy and paste during initial development.
- A QR code.
- A nearby exchange.
- A relay rendezvous address.
- An exported invitation file.

The joining Mac, iPhone, or Watch does not trust an authority merely because discovery found it. The invitation identifies the expected authority. Discovery only provides a possible route to that authority.

### Local-network discovery

When both devices are online on the same LAN:

1. The authority advertises an enrollment service through Bonjour.
2. The joining device discovers possible enrollment endpoints.
3. It considers only an advertisement matching the invitation's network and authority information.
4. It establishes an authenticated connection.
5. Both sides prove possession of their respective private keys.
6. The administrator explicitly approves the request.

Bonjour answers where the invited authority might be reached. It never determines whether that endpoint is trusted or authorized.

A physical device may be able to reach a service running in Simulator through the host Mac's networking. That behavior can depend on Simulator networking, local-network permissions, Bonjour behavior, and the Mac firewall, so it must not be the only supported enrollment path.

### Relay rendezvous

If the authority and joining device are not on the same LAN, an invitation may carry a short-lived relay rendezvous reference:

```text
Joining device
      │
      └── relay rendezvous ── authority device
```

The relay may forward or temporarily queue bounded enrollment messages. It cannot issue credentials or authorize membership. Because the invitation pins the expected authority identity, a compromised relay cannot substitute a different authority.

An invitation may offer both LAN and relay routes. Existing Beakr route selection may choose an available route, but route discovery and availability remain advisory. Authentication and authorization are independent of the selected route.

### Temporary authority outage

Different operations have different behavior while the primary authority is offline.

#### Existing enrolled nodes

Already enrolled nodes should normally continue communicating while all of the following remain valid:

- Their node credentials.
- Their certificates or authenticated session material.
- Their cached revocation state under the configured freshness policy.
- Their normal route eligibility.

Routine Beakr traffic does not require the authority to remain continuously online. The authority is not an intermediary for normal messages.

#### New enrollment

A new device cannot complete enrollment while the only authority is offline. No authorized signer is available to approve the request and issue its credential.

The joining device may:

- Retain its locally generated identity.
- Submit or queue a bounded enrollment request through the relay.
- Display **Waiting for an administrator**.
- Complete enrollment when an authorized authority returns.

The waiting device must not receive temporary membership or normal route authorization.

#### Credential and certificate renewal

Existing nodes may continue until their credentials, certificates, or authenticated session material approach expiry. If renewal requires the authority or its control-plane service, renewal waits until that service becomes available.

Credential validity and the renewal window therefore define the tolerated authority outage. Validity periods must not be so short that an ordinary phone shutdown unnecessarily disables the network.

#### Revocation state

Nodes use their most recently authenticated revocation snapshot. If it becomes older than the existing maximum freshness policy, Beakr continues to follow that policy and may disable routes rather than assuming that no devices were revoked.

Enrollment convenience must not weaken revocation freshness enforcement.

#### Revoking a device

A new revocation cannot be authoritatively signed while the only authority is unavailable. An administrator interface may record a pending intent, but enforcement cannot propagate until an authorized authority signs and distributes updated revocation state.

### Temporary shutdown versus permanent loss

A temporary shutdown is an availability event:

- Existing communication continues within credential and revocation-freshness limits.
- Enrollment and administrative operations wait.
- Bounded pending requests may resume when the authority returns.

Permanent loss is a recovery event. Recovery requires either:

- An explicitly designated backup administrator, or
- Restoration from separately protected authority recovery material.

Without either mechanism, existing nodes may communicate temporarily, but the network eventually becomes administratively unrecoverable as credentials, certificates, or revocation freshness expire. Even the initial single-authority release therefore requires an explicit recovery plan.

### Simulator authority limitations

Using a virtual iPhone as the first authority is appropriate for disposable development tests, but it must not be treated as a durable production authority because:

- Simulator devices can be erased or recreated.
- Their Keychain and application data can be deleted.
- Availability depends on the host Mac and Simulator process.
- Network reachability can differ from a physical device.
- Signing keys may not receive equivalent hardware-backed protection.

A recommended Simulator test sequence is:

1. The Simulator creates a disposable network.
2. A physical iPhone or Mac imports its invitation.
3. The Simulator approves enrollment.
4. The Simulator is shut down.
5. Existing enrolled nodes are verified to continue communicating within policy limits.
6. A new device is verified to remain pending rather than joining.
7. The Simulator is restarted and pending enrollment resumes.
8. The Simulator is erased and the authority is treated as lost rather than silently regenerated under the previous network identity.

For a persistent personal network, a physical Mac is generally the strongest primary-authority candidate because it is more likely to remain available. A physical iPhone is also viable when protected recovery or a designated backup administrator has been established.

The governing rule is:

> Discovery finds a route to the authority identified by an invitation. Discovery never decides which node is the authority. Existing membership survives ordinary authority outages within established validity and freshness limits, while new authorization requires an available authority or explicitly established recovery administrator.

## Network creation and multi-network membership

A Beakr installation can create a new logical Beakr network. Creating a network generates a new and independent trust domain containing:

- A unique Network ID.
- A new authority identity and signing key.
- An initial administrator role for the creating installation.
- An initial node credential bound to that network.
- Independent membership and revocation state.

It does not create another application installation or necessarily start a separate server process.

```text
Beakr installation
└── Beakr network
    ├── Network ID
    ├── Authority
    ├── Members
    ├── Credentials
    └── Revocation state
```

Two independently created networks do not trust each other merely because the same Beakr installation created them.

### First-release rule

For the first release, each Beakr installation should support one active network:

```text
No network configured
├── Create Network
└── Join Network

Network configured
├── Use Network
├── Administer Network, when authorized
└── Leave or reset Network
```

Selecting **Create Network** while already configured must never silently overwrite the current network. Leaving or resetting requires an explicit operation that explains its effect on local credentials, authority recovery, queued data, and continued access by other members.

The governing first-release rule is:

> A fresh Beakr installation may create one new network or join one existing network. Multi-network membership is a future profile feature.

### Future multi-network model

A single physical Beakr device can technically participate in more than one Beakr network, but this should be implemented later as explicit, isolated profiles:

```text
Beakr installation
├── Family Network profile
├── Work Network profile
└── Test Network profile
```

Each profile requires independent:

- Network identity and authority trust anchors.
- Node credential and role assignments.
- Revocation and freshness state.
- Sessions and route eligibility.
- Persistent queues and application data.
- Enrollment, renewal, and recovery state.
- Diagnostics and resource limits.

Using a distinct node identity for each network is preferred because it prevents unrelated networks from correlating the device through a shared Node ID. If a device-level identity is retained internally for secure storage or recovery, it must not automatically become a cross-network protocol identity.

### Consumer device identity and administration

Commercial managed-network products commonly separate a stable installation or machine identity, a replaceable network-membership credential, and an authority-side device record that an authorized person can approve, revoke, or remove. BeakrNet should preserve these security boundaries without requiring casual Apple users to understand enterprise administration terminology. The device that creates a network is effectively its first administrator even when the interface calls it the network creator or manager.

A consumer-oriented model should have these properties:

- Each Beakr installation has a stable private installation identity in protected local storage.
- Each network sees a distinct, privacy-preserving device identity; unrelated network authorities must not receive a shared global identifier that lets them correlate the device.
- The stable identity supports recognition only. It never grants network access by itself.
- Initial enrollment and re-enrollment require approval from a device currently authorized to manage that network.
- Membership credentials are independent, replaceable, expiring, and revocable.
- Forget Network removes the local membership and selected local state. When possible, it also sends a signed departure notice, but local cleanup must remain possible while the authority is unavailable.
- An authority may retain an offline device record after an offline Forget until it receives the departure notice or a network manager removes the device.
- Rejoining may be presented as a previously registered device requesting fresh approval, but recognition must never silently restore access.
- Device names are descriptive metadata rather than identities. A shared device or renamed device must not gain authorization from its name.
- Restoring or replacing an Apple device must not automatically copy an operational network identity to another physical device without an explicit recovery policy.

The consumer interface should expose ordinary actions such as **Forget Network**, **Registered Devices**, **Remove Device**, **Rejoin**, and **Delete Network**. Internally these actions must retain the distinction between recognition, membership authorization, authority capability, and revocation.

The core rule is:

> Stable identity may help the authority recognize a returning installation, but only a current authority decision may authorize it.

### Apple-native authority protection and recovery

Normal Beakr administration should use the security ceremony Apple users already understand. Beakr should not require a separate application password for creating or managing a network. Authority keys and sensitive administrative capabilities should be protected by Keychain access controls and, where suitable, the Secure Enclave. Approving, removing, or promoting a device should require user presence through Face ID, Touch ID, the device passcode, or the equivalent Mac authentication experience.

Authority promotion should use redundancy rather than copying a private authority key. The receiving device generates its own protected authority key, the current authority signs an update recognizing that key, and the updated authority state is distributed before an old authority is retired. A designated backup authority can then revoke and replace a lost primary authority after authenticating its local user through Apple security.

The key on a lost sole-authority device cannot be recreated merely by knowing that device's passcode. Release 1 should therefore support or clearly plan for explicitly promoted backup authorities and explain the consequence of operating with only one authority. A future optional Apple-account-backed recovery mechanism may be considered, but it changes the trust model because the Apple account and synchronized Keychain become part of recovery. A universal Beakr password must not directly grant authority.

The governing usability rule is:

> Beakr uses Apple device authentication for routine authority operations and uses independently protected backup authorities for recovery, without asking the user to manage another password.

### Local Context ownership after Forget

Local application data belongs to the device owner's Beakr installation and its preserved network Context, not to the currently active Node ID or membership credential. A Context may own messages, attachments, Blackboard state, queues, and related metadata. It should be protected at rest by the Apple device and application sandbox, with any additional local data-protection keys secured independently from disposable network identity and membership keys.

Forgetting a network must distinguish disconnecting from deleting data:

- **Keep Data on This Device** removes active membership credentials and connections while detaching and preserving the Context.
- **Delete Data from This Device** removes the membership, preserved Context, local data-protection material, and every associated Keychain item.

A preserved Context remains locally accessible to the authenticated device owner, although operations requiring the network may be read-only or unavailable. A later membership for the same Network ID may reattach to that Context after explicit user confirmation. A changed Node ID must not make already stored local data unreadable.

The governing storage rule is:

> Network identity controls future communication and synchronization; it does not determine whether the device owner may read data already stored in a preserved local Context.

### Consolidated Apple-native security model

BeakrNet should adopt the useful security separation of a commercial managed-network product without exposing an account-centric or enterprise-administration experience. Apple device authentication establishes that the device owner approved a local action. Beakr authority establishes who may manage a network. Membership establishes which devices may communicate. A local Context establishes ownership of data already stored on a device.

#### Beakr application

- Trust the Apple device as the user-facing security boundary.
- Use Face ID, Touch ID, the device passcode, or Mac authentication for sensitive actions instead of introducing a Beakr password.
- Keep private keys in Keychain and, where appropriate, the Secure Enclave.
- Maintain a stable private installation identity for continuity while exposing a distinct identity to each network.
- Present consumer concepts such as networks, registered devices, approvals, removing devices, keeping data, and deleting data.
- Give every Keychain item an explicit owner and deterministic replacement and deletion lifecycle; orphan certificates, keys, and profile records are defects.

#### Network administration

- The network creator becomes the first authority without requiring enterprise terminology in the interface.
- Authority capability remains separate from ordinary membership; a normal registered device cannot approve or remove other devices.
- Promoting another device requires an existing authority decision plus Apple device authentication.
- The promoted device generates and protects its own authority key. Private authority keys are not copied between devices.
- A network may recognize more than one authority-capable device so that a surviving authority can revoke and replace a lost authority.
- Operating with a sole authority must be presented as a recovery risk. Future Apple-account-backed recovery may be optional, but it adds the Apple account and synchronized Keychain to the trust model.

#### Device operations

Device lifecycle keeps three concepts separate:

1. **Installation identity** is stable and private to a Beakr installation. It supports continuity but never grants network access.
2. **Network device identity** is distinct for each network and prevents unrelated networks from correlating the device.
3. **Membership credential** is issued by that network's authority and is replaceable, expiring, and revocable.

Recognition is not authorization. Joining creates or presents a network-specific identity and requests approval. Rejoining may recognize a previous installation but still requires fresh approval. Forget Network removes membership credentials and active connectivity and sends a signed departure notice when possible. Remove Device is an authority operation that revokes the device. Promote Device grants authority capability using the receiving device's own protected key. Delete Network removes locally owned network state and every associated credential and Keychain object.

An offline Forget may temporarily leave an authority-side device record. It should appear as offline or formerly registered, remain removable by a network manager, and must not silently become a second active registration if the same installation rejoins.

#### Data stores

- Local data belongs to a preserved network Context rather than a disposable Node ID or membership credential.
- Contexts own messages, attachments, Blackboard state, queues, and related metadata.
- Local data remains inside Beakr's application sandbox and under Apple device protection; it is not public to unrelated applications.
- Data-at-rest keys remain independent from network identity and membership keys.
- Changing a Node ID must not make existing local data unreadable.
- Rejoining the same Network ID may reattach a new membership to the preserved Context after explicit confirmation.

Forget Network should offer **Keep Data on This Device**, which preserves the locally accessible Context, and **Delete Data from This Device**, which removes the membership, Context, stored data, local protection keys, and associated Keychain entries.

### Release 1 implementation recommendation

The duplicate-registration defect exposed coupled identity, authority, Keychain, and data-ownership decisions. Release 1 should establish the security contract before treating the symptom as a presentation problem.

The persistent-object lifecycle must define when each object is created, whether it survives Forget, how it rotates, and what deletes it:

| Object | Created | Survives Forget | Rotated | Deleted |
| --- | --- | --- | --- | --- |
| Installation identity | First launch | Yes | Exceptional recovery | Application security reset |
| Network device identity | First join to a Network ID | Only with an explicitly retained Context | Re-enrollment policy | Permanent network-data deletion |
| Membership credential | Approval | No | Renewal or rejoin | Forget, revocation, or expiry |
| Authority key | Network creation or promotion | Only while authority is retained | Authority transition | Network deletion or authority revocation |
| TLS key and certificate | Enrollment | No | Renewal | Replacement, Forget, or deletion |
| Preserved Context | First local network use | User choice | Not applicable | Delete Data |
| Local data key | Context creation | With its retained Context | Supported key rotation | Context deletion |

Implementation proceeds in dependency order:

1. Audit every creation, replacement, rollback, Forget, network deletion, and Context deletion path for Node identities, authority keys, TLS material, CA certificates, membership credentials, enrollment records, Context data, and data-protection keys.
2. Give every Keychain object explicit ownership, recognizable metadata, deterministic replacement, and deterministic deletion.
3. Separate Context retention from membership deletion and implement distinct Keep Data and Delete Data outcomes.
4. Establish stable installation continuity and privacy-preserving per-network identity without allowing recognition to grant authorization.
5. Correct Forget and rejoin so the same installation cannot silently create a second active registration for the same network.
6. Provide authority-side Remove Device backed by revocation.
7. Require Apple authentication for destructive and authority-sensitive operations.
8. Add migration handling for existing profiles and orphaned development-era Keychain entries without silently deleting active material.

Release 1 validation must cover online and offline Forget, both data-retention choices, rejoin with and without preserved data, credential and certificate renewal, failed and cancelled enrollment cleanup, device revocation, sole-authority loss, application update and reinstallation behavior, restoration behavior, and migration of existing Release 1 test data.

Renaming the production application is not a Keychain-lifecycle solution. The display name does not reliably rename Keychain services or existing objects, while changing the bundle identifier or access groups may strand credentials and create additional artifacts. Keychain isolation experiments should use a separate diagnostic build identifier and explicit namespace.

A device may eventually maintain connections to several network profiles concurrently, but each profile requires a separate host/session context. Data, routes, credentials, acknowledgements, and control messages must never cross profile boundaries.

Membership in two networks does not authorize the device to bridge them. Cross-network forwarding or relay behavior would require a separate, explicit capability and policy approved by both trust domains. It is outside the initial enrollment scope.

### Logical networks and physical networks

A Beakr network is a logical trust network, not a physical LAN. For example, a Red profile and a Blue profile may occupy completely different physical networks:

- Red nodes might currently be attached to a home Wi-Fi network.
- Blue nodes might currently be attached to an office network.
- Red may also contain nodes distributed across several physical networks and connected through an authorized relay.
- One device may participate in both Red and Blue using isolated profiles, credentials, sessions, queues, and storage.

Sharing a physical LAN does not grant membership in the same Beakr network. Authentication against the selected profile and its authority determines membership. Conversely, physical separation does not prevent two nodes from belonging to the same Beakr network when an authenticated route such as a relay is available.

Bonjour provides local-network discovery only. A Red node cannot discover another Red node on a different physical LAN using Bonjour alone. Cross-LAN discovery requires an approved rendezvous mechanism, configured relay, invitation information, or another authenticated discovery path. Route discovery and availability remain advisory: neither Bonjour nor a relay may authorize membership.

Multi-network support therefore requires more than an account selector. It adds isolation, lifecycle, scheduling, notification, storage, and user-interface requirements and should follow successful delivery of the single-network enrollment model.

### Authority listener ports and collision handling

The authority listener port belongs to a network authority endpoint, not to Beakr as a global application setting. Bonjour advertises the resolved service host and listener port, so joining devices discover the endpoint dynamically rather than assuming that every Beakr authority uses a fixed port such as `8443`. A saved authority endpoint may retain the same host and port for direct reconnection and diagnostics.

For a newly created network, a future implementation should allow the operating system to select an available port, then persist and advertise the assigned port for that authority. Once assigned, normal startup should attempt to reuse it. Beakr must not silently choose another port whenever binding fails: the existing listener may be another Beakr process, and changing ports without an authenticated endpoint update could produce conflicting authority state or cause devices to connect unpredictably.

Listener startup failure should distinguish these cases where possible:

- If the existing listener can be authenticated as the same Beakr authority, report that another copy of Beakr is running.
- If the listener is unrelated or cannot be verified, report a port conflict requiring attention.
- If an established authority endpoint must move, perform an explicit controlled migration that updates and signs the authority configuration before advertising the replacement endpoint.

Release 1 retains its stable configured port and visible red collision state. It does not expose an editable global port or automatically migrate an occupied endpoint. This behavior keeps duplicate development instances diagnosable and avoids masking a real collision.

The authority port should remain visible as read-only diagnostic information in Network Parameters. The existing authority endpoint display already provides the Bonjour host and port number for Release 1. A later presentation may separate that value into `Address` and `Port`, but neither should normally require casual users to configure networking manually.
