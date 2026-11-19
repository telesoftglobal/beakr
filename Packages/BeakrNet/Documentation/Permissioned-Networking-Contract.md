# Permissioned Networking Object and Command Contract

_Status: proposed architecture for review, October 25, 2026. Documentation only; not an implemented API or permission schema._

## Scope and adoption boundary

This document defines the first reviewable contract for entities that interact with Beakr networking. It maps existing code to proposed responsibilities and specifies what future code must be allowed to change.

Release 1 stabilization continues. This proposal does not begin Release 2, change wire formats, regenerate identities, migrate stores, enable simultaneous networks, or introduce agent execution. Network colours and Device/Node interface terminology remain unresolved and unchanged.

Existing [package dependency boundaries](Package-Architecture-and-Testing.md), authentication, signed membership, revocation freshness, transport semantics, and Context preservation remain constraints. [Authority-managed capabilities](Authority-Managed-Network-Capabilities.md) remain deferred. Proposed type names do not authorize renaming public interfaces.

## 1. Principles that constrain implementation

1. Every mutable fact has one responsible writer and a documented source of authority.
2. UI and application services invoke commands and consume immutable snapshots; they do not mutate repositories or credentials.
3. Identity, permission, desired configuration, runtime activity, and retained information have separate lifetimes.
4. A local Actor ID is not a network credential. A connection's authenticated Node ID is not proof of an arbitrary claimed actor.
5. Admission to one network gives no rights in another. Service bindings select a membership explicitly.
6. Missing, malformed, expired, or insufficient authority fails closed for the affected operation. Existing offline trust rules are preserved, not replaced by a blanket requirement to contact the authority.
7. Local users may stop local participation without remote approval. Network-wide changes require network authority.
8. Accepted durable work is saved before acceptance is reported. Delivery and remote execution are separate outcomes.
9. Interrupted multi-store operations have explicit recovery steps. Files, Keychain, and remote state cannot be treated as one atomic transaction.
10. Retained Context data is not owned by a connection or membership's lifetime.
11. No stored “connected” flag is restored as a current fact.
12. New commands, permissions, and state transitions require contract changes and matching tests.

## 2. Entity definitions

These are logical objects, not a requirement for one file or Swift class per row. IDs are typed and stable; references use IDs rather than duplicated nested objects.

| Entity | Identity and cardinality | Saved facts | Responsible writer and allowed changes |
| --- | --- | --- | --- |
| DeviceProfile | One per local installation; Installation ID | Friendly name, preferences, ServicesProfile reference, format version | Installation coordinator initializes once and updates local preferences. Does not grant network authority. |
| ServicesProfile | One local inventory per DeviceProfile | Configured service references and local enablement preferences | Service coordinator adds/removes configuration and changes desired enablement. Installed implementations are discovered separately. |
| Actor | Local Actor ID; initially the local user and application service callers | Only actor metadata/grants that require durable identity | Trusted application composition establishes caller context. No caller can impersonate an actor by supplying a UUID. Remote actor identity is deferred. |
| Network | Shared Network ID | Verified authority identity and policy snapshots with generations/validity as supported | Authority changes policy; member-side trust coordinator verifies and installs snapshots. Display names are not identity. |
| NetworkMembership | Existing local Profile ID, Network ID, local Node ID; at most one configured membership per Network ID under current rules | Enrollment state, credential references, trust references, local configuration | Membership coordinator performs create/join/refresh/forget procedures. Existing identifiers are preserved. |
| ServiceBinding | Binding ID, local service instance ID, one Membership ID, protocol/service identifier | Explicit association and local configuration if binding is durable | Service coordinator validates configuration; networking issues a restricted runtime handle. A closed handle is not an admission revocation. |
| PermissionGrant | Issuer, subject, operations, resource scope, validity and policy provenance | Existing signed capabilities/credential scopes remain the initial network evidence | Only an authorized issuer can grant network rights. Local restrictions may narrow, never enlarge, those rights. No new generic signed grant format is approved here. |
| NetworkSession | One stable application object per configured membership while app runs | No independent copy of membership truth | Runtime coordinator updates read-only snapshots from verified state and runtime events. This is distinct from transport/protocol Session IDs. |
| OperationRecord | Operation ID and target IDs | Durable progress, version, retry identity, safe failure category | Command owner records and recovers multi-step operations. Reuse enrollment records where they already cover the procedure. |
| ContextRecord | Existing Context ID and Store IDs | Retained information and historical membership/network associations | Context repository owns data lifecycle. Networking may request detach; deletion is a separate explicit data command. |

Authority hosting needs a configuration associated with a Network and protected authority-key references. It is separate from the host's ordinary membership. A member cannot become an authority merely by setting a role field locally.

A ServiceMember, if exposed in a future UI, is initially a view of membership + service eligibility + local binding. It must not introduce an independently editable admission database.

## 3. Persistence and reconstruction

Proposed clean first launch: initialize DeviceProfile and an empty ServicesProfile idempotently. Create no network membership, network identity key, authority, Context, or service connection. This differs from current bootstrap, which creates no explicit DeviceProfile/ServicesProfile.

| Category | Persistence rule | Restart rule |
| --- | --- | --- |
| Profiles, memberships, bindings | Versioned durable records; one writer; atomic record replacement or repository transaction | Validate versions and references before use; never silently overwrite damaged state with empty state. |
| Signed trust/policy evidence | Preserve provenance, validity, generation and verification rules | Reverify and reconcile under existing freshness policy before protected operations. |
| Secrets | Protected credential-store interface; records contain references, not private keys | Missing or inaccessible secrets produce a defined recovery/blocking state, not silent replacement identity. |
| Messages and pending delivery | Existing durable Data/Context repositories | Recover using stable message IDs and duplicate suppression. |
| Enrollment/other durable operations | Persist progress before irreversible or externally visible steps | Resume idempotently or expose recovery required. Do not claim remote rollback when only local cleanup occurred. |
| Sessions, handles, connections, tasks | Memory | Reconstruct; previous handles become invalid after process restart. |
| Peer presence and availability | Temporary observations with expiry | Rediscover; unknown is not admitted, online, or revoked. |
| Diagnostics | Bounded, privacy-safe retention | Useful evidence only; never an authorization source. |

A database choice is not required for this contract. Initially retain existing JSON, preferences, Keychain, and repository implementations behind their owners. Backups, installation identity across restore/reinstall, retention limits, and migrations require explicit policies before new persistence is implemented.

## 4. Sources of state

| Dimension | Examples | Source |
| --- | --- | --- |
| Admission | Pending, admitted, revoked, recovery required | Enrollment procedure and verified authority evidence |
| Local intent | Enabled, disabled | Saved local configuration |
| Runtime lifecycle | Stopped, starting, running, stopping, failed | Runtime coordinator |
| Availability | Unknown, available, blocked with reason | Platform/resource/trust observations |
| Peer presence | Authenticated peers and last observations | Connection subsystem |
| UI selection | Selected row/window | Presentation state only |

A proposed transition reducer consumes current facts and an event, then returns a new snapshot and required effects. Reducers do not write files or open sockets. Coordinators perform effects and feed back results.

Use serialization plus operation generations/revision checks; Swift actor isolation alone does not prevent reentrancy across await points. A late completion for a stopped or replaced session cannot reactivate it. Shared active-runtime transitions must coordinate across memberships, not only within one membership.

Policy changes invalidate affected handles or cause authorization to be reevaluated at use. Queued work is rechecked before transmission. Incoming work is checked before dispatch or mutation. Permission revocation does not retroactively retract data already delivered.

This design does not select colours or collapse all these dimensions into one “active” Boolean.

## 5. Restricted interfaces and caller provenance

| Interface | Holder | Surface |
| --- | --- | --- |
| NetworkInspection | Authorized local UI/service observers | List permitted membership summaries; read/observe scoped status |
| LocalNetworkManagement | Trusted local-user adapter | Create, request join, activate, stop, refresh trust, forget |
| NetworkAdministration | Authorized administration adapter | Approve/reject enrollment, revoke membership, approved policy operations |
| BoundNetworkService | Validated service instance | Submit permitted traffic, consume authorized inbound traffic, observe its binding, close |
| InternalRuntimeEvents | Platform/transport adapters | Report connection, path, execution and storage facts; no grant mutation |

The trusted composition root supplies these interfaces. Actor context and service handles cannot be constructed from arbitrary public IDs. Domain Actor is an identity concept; Swift actor is a concurrency mechanism.

Service implementations receive no raw credential access, administrative facade, or repository mutation interface. Incoming traffic reaches them only after network checks. Application-operation authorization remains the receiving service's responsibility.

These boundaries constrain accidental misuse by trusted code. They do not isolate hostile code in the same process. Untrusted plugins, remote actors, delegation, and process isolation are separate future designs.

## 6. Common command contract

Every command specification must declare:

- Trusted caller context, target IDs, operation ID for retryable mutations, and expected revision when applicable.
- Required local authorization and/or verified network authority.
- Preconditions and allowed state transitions.
- Durable writes, side effects, and their order.
- Precisely what “accepted” and “completed” mean.
- Typed failure categories, cancellation behavior, idempotency and restart recovery.
- Scoped events emitted, with no payloads or secrets in routine diagnostics.
- Positive, denied, interruption, stale-result, and cross-network tests.

Authorization errors are distinct from unavailable resources, stale trust, invalid input, conflicting operations, persistence failure, and recovery-required results. A diagnostic string is never control flow.

## 7. Command catalogue

This is a closed proposed boundary, not a new public API already implemented.

| Command | Authority/preconditions | Durable effect and completion | Failure/retry rule |
| --- | --- | --- | --- |
| initializeInstallation | Trusted local application bootstrap | Commit versioned Device/Services inventory; complete when readable and consistent | Repeated initialization preserves ID; partial initialization recovers; damaged existing records are not replaced |
| createNetwork | Local user; supported authority hosting and valid configuration | Create authority, initial membership, trust and operation state; report created only after consistent durable installation | Record partial work; retry by operation identity; retain existing creation security checks |
| requestJoin | Local user; verified invitation, no duplicate configured membership | Save pending identity/membership and request; acceptance means request staged/submitted, not admission | Resume existing request; signed rejection/cancellation has explicit cleanup |
| activateMembership | Local user; existing configured membership | Reconcile saved active selection and start eligible runtime | Never fabricate admission; report blocked/failed activation explicitly; see detailed contract below |
| stopMembership | Local user or lifecycle coordinator | Stop affected runtime and invalidate handles; preserve membership/data | Idempotent; stopping a runtime is distinct from saving a disabled preference |
| refreshTrust | Local user or scheduled trusted maintenance | Install only verified non-rollback trust state and reconcile affected operations | Authority unavailable preserves existing freshness rules; no automatic authorization extension |
| forgetMembership | Local user; local member profile, not owned-network deletion | Remove local participation, revoke handles, detach Context, remove scoped secrets/configuration | Durable progress and idempotent cleanup; preserve Context; see detailed contract below |
| approve/rejectEnrollment | Network administrator with required request-specific local authorization | Existing authority enrollment transaction updates durable request/member state | Replay protection and retry behavior owned by enrollment coordinator; no duplicate admission |
| revokeMembership | Network administrator with required local authorization | Commit and publish signed authority state | Completion is authority commit, not proof all offline devices learned it |
| updateNetworkPolicy | Authorized network administrator; supported policy operation | Publish validated next policy generation | Only existing operations during Release 1; generalized service/provider policy remains deferred |
| openBinding | Trusted registered service; configured membership and permitted protocol | Validate association, optionally persist configuration, issue scoped handle | Handle confers no broader rights; live availability may remain blocked |
| send | Valid binding and current authorization; bounded payload and explicit destination | Existing Data service durably accepts work when requested by its contract | Stable Message ID for retries; acceptance is not delivery; see detailed contract below |
| receive | Authenticated internal transport context; eligible binding and authorized envelope | Existing Data/application boundary performs deduplication and durable acceptance | Never a public “inject trusted message” API; acknowledgment follows existing acceptance contract |
| closeBinding | Holder or local lifecycle coordinator | Invalidate runtime handle and stop binding activity | Idempotent; does not implicitly delete saved configuration or queued content |
| inspect/observe | Caller has scoped visibility | No domain mutation | Snapshot/event revisions prevent stale observations being treated as newer truth |

Deleting an owned network, deleting retained data, creating invitations, credential rotation, and authority recovery remain distinct existing workflows. Before routing them through the new facade, each must receive an equally explicit contract. They must not be smuggled into forget, stop, or policy update.

## 8. Detailed first migration contracts

### activateMembership

Input: trusted local caller, target Membership ID, operation ID. Selection in a window is not proof of activation.

1. Validate the target and serialize against all active-runtime transitions.
2. Snapshot current selection and stop the prior runtime through its owner; invalidate stale handles/callback generations.
3. Persist target selection using the registry; recover/reconcile it explicitly on failure.
4. Load existing identity and verified trust. Never create a replacement key to repair a mismatch.
5. Start eligible existing services and publish a snapshot.
6. Return operational, blocked with reason, or failed with recorded state. “Selected” does not imply “connected.”

A retry reconciles the actual registry/runtime state even if UI selection already equals the target. A crash restores recorded selection and reassesses eligibility. A failure must leave one coherent reported state, not silently restore only a UI label. Preserve the current single active application runtime during initial migration; no simultaneous-network expansion.

### forgetMembership

Input: trusted local caller, Membership ID, operation ID. This command always preserves retained Context data.

1. Validate local ownership of configuration and reject using this command for owned-network retirement.
2. Persist removal intent before destructive cleanup.
3. Block new work for this membership, stop its runtime, and invalidate handles.
4. Detach retained Context and remove the membership from configured inventory.
5. Delete only that membership's credential/configuration material; recover remaining cleanup after restart.
6. Publish the new inventory. Apply the separately specified active-selection policy.

Completion means local participation has been removed; it does not claim remote revocation or message deletion. Retained pending work cannot migrate to another network or resume under a new membership without an explicit authorization/rebinding rule.

The “exactly one usable network remains” policy needs a precise eligibility definition. Current code tests remaining profile count, then attempts activation. Do not silently describe that as already filtering for usability.

### send

Input: trusted bound service handle, explicit destination, permitted protocol/channel, bounded payload, stable Message ID and applicable deadline.

1. Resolve the handle's service and membership; reject a caller-supplied network substitution.
2. Validate binding, membership, current trust, destination eligibility and operation scope.
3. Apply the existing channel-specific admission contract. Durable application Data uses existing queues; Control is not made durable.
4. Return acceptance only after required durable storage succeeds.
5. Recheck eligibility before dispatch; retries retain identity and network binding.
6. Report delivery outcomes independently from application processing and read receipts.

Stopping/closing a binding blocks dispatch. Retained work remains subject to expiry and explicit cancellation policy. A changed permission cannot be bypassed by a previously issued handle or an already queued message. Remote message content never grants permission to execute its requested operation.

## 9. Current implementation mapping

Paths below are repository-relative. Findings describe the inspected working tree, including uncommitted Release 1 work, rather than only the October 16 checkpoint.

| Existing code | Current responsibility/evidence | Proposed disposition |
| --- | --- | --- |
| [BeakrApp.swift](../../../Apps/Beakr/BeakrApp.swift), BeakrApplicationModel | Constructs shared composer, LAN manager and bootstrap | Keep as composition entry; supply restricted interfaces rather than broad mutable models |
| [NodeBootstrapModel.swift](../../../Apps/Beakr/NodeBootstrapModel.swift) | UI-facing state plus creation/join/switch/removal/trust/runtime orchestration | Gradually extract command ownership; retain a presentation adapter while migrating |
| NetworkSession in NodeBootstrapModel | Stable configured-network object and state projection | Preserve object identity; make its snapshots coordinator-owned |
| [NetworkProfile.swift](../Sources/BeakrNetCore/NetworkProfile.swift) | Local Profile ID, Network ID, Node ID, display name and registry | Reuse identity and registry for membership; avoid a second inventory or identity migration |
| SystemApplicationProfileRuntimeManager in NodeBootstrapModel | Opens profiles.json/contexts.json and profile runtime storage | Place behind repository/runtime ownership interfaces; preserve storage locations initially |
| [ContextRegistry.swift](../Sources/BeakrNetCore/ContextRegistry.swift) | Context/store identity, attachment and retention independent of membership | Retain; networking requests detach, not implicit content deletion |
| [ApplicationLANRuntimeManager.swift](../../../Apps/Beakr/ApplicationLANRuntimeManager.swift) | LAN lifecycle, authenticated peers, trust reconciliation and messaging integration | Adapt behind NetworkSession runtime and restricted service binding |
| [MessageComposerModel.swift](../../../Apps/Beakr/MessageComposerModel.swift) | Draft/UI/mailbox state and HostMessagingService use | Retain application semantics; receive only scoped networking access |
| [AuthoritativeNetworkCreator.swift](../../../Apps/Beakr/AuthoritativeNetworkCreator.swift) | Mac authority creation/restoration and protected secret custody | Preserve adapter; authority hosting remains platform capability, not an assumed right on every device |
| [JoiningEnrollmentCoordinator.swift](../Sources/BeakrNetEnrollment/JoiningEnrollmentCoordinator.swift) | Staged request/approval/confirmation and resumable installation | Reuse as join command implementation; do not duplicate operation journal |
| [AuthorityEnrollmentCoordinator.swift](../Sources/BeakrNetEnrollment/AuthorityEnrollmentCoordinator.swift) and [AuthorityPolicy.swift](../Sources/BeakrNetEnrollment/AuthorityPolicy.swift) | Authority request decisions, required local authorization and bounded policy | Preserve trust and transaction rules; wrap with restricted administration interface |
| [LocalAuthorizationGrantAuthority.swift](../Sources/BeakrNetEnrollment/LocalAuthorizationGrantAuthority.swift) | Short-lived, request-bound local approval proof using an in-memory key | Not a general persistent Actor permission grant or remote identity; preserve its distinct purpose |
| [AuthorityTrustStateCoordinator.swift](../Sources/BeakrNetAuthority/AuthorityTrustStateCoordinator.swift) | Authority trust-state coordination | Reuse signed evidence; avoid parallel editable admission truth |
| [HostServices.swift](../Sources/BeakrNetHost/HostServices.swift), [ProfileRuntimeStorage.swift](../Sources/BeakrNetHost/ProfileRuntimeStorage.swift) | Lifecycle/service boundaries and isolated runtime repositories | Extend existing seams where appropriate; no dependency from networking to Beakr UI/product schemas |
| [BeakrTests.swift](../../../Apps/BeakrTests/BeakrTests.swift) and package tests | State, enrollment, trust, storage and delivery tests | Map existing tests to contract IDs before adding focused missing cases |

DeviceProfile, ServicesProfile, general Actor records and explicit ServiceBinding are proposed concepts, not current persisted types. Current device friendly name is a preference. Existing capability/scope checks are evidence for permission decisions; they are not proof of per-actor authorization.

## 10. Acceptance scenarios

| ID | Scenario | Required observation |
| --- | --- | --- |
| C01 | Fresh initialization, repeated and interrupted | One installation identity and empty service inventory; no network keys/Context |
| C02 | Hamilton and Queens memberships | Independent credentials and trust; no cross-network binding/queue routing |
| C03 | UI shows Queens but internal selection differs | Explicit activation reconciles registry and runtime or reports failure |
| C04 | Stop/switch while startup is awaiting I/O | Late callback cannot restart old runtime or overwrite new status |
| C05 | Join pending, restart, then approval | No protected service before admission; same staged request recovers |
| C06 | Local service lacks send scope | Reject before enqueue/dispatch; no new durable message accepted |
| C07 | Message queued, then permission revoked | No prohibited dispatch once revocation is verified; retained data policy respected |
| C08 | iPhone offline during authority revocation | No claim of instant propagation; existing freshness constraints and Refresh apply |
| C09 | Forget Queens with saved messages | Queens participation removed; Context preserved; Hamilton data unchanged |
| C10 | Crash after registry removal, before secret cleanup | Resume scoped cleanup without losing Context or resurrecting membership |
| C11 | Exactly one remaining profile cannot activate | Explicit blocked/failure result; no false operational success |
| C12 | Two Mac windows observe same membership | Same underlying revision/state; independent window selection is presentation only |
| C13 | Duplicate send after ambiguous connection loss | Stable ID and existing deduplication; no new logical message |
| C14 | Damaged store or inaccessible Keychain | Recovery/blocking state; no silent empty registry or replacement identity |
| C15 | Local Actor ID forged in message payload | No additional authority; existing authenticated membership checks remain decisive |

These are required future verification scenarios, not claims of test execution. Known baseline from the handoff: focused state tests 5/5; earlier complete BeakrTests 36 passed, 9 failed in trust-dependent fixtures/state. Build success does not supersede those failures. No tests were rerun for this document.

## 11. Migration sequence and review decisions

1. Review this entity/command contract against Hamilton/Queens behavior. Resolve decisions below before dependent code.
2. Add a test-to-contract mapping and characterize activation/stop behavior, including failures. Repair missing trust fixtures without weakening checks.
3. Extract activation/stop coordination behind existing models and storage. Keep IDs, UI behavior, colours and single-active-runtime behavior intact.
4. Introduce scoped messaging access around existing HostMessagingService/Data semantics; no new wire format.
5. Wrap existing enrollment/removal coordinators and close direct mutation paths incrementally.
6. Introduce Device/Services inventory only after schema, recovery and migration decisions are reviewed. Existing users must not be initialized as fresh installations.
7. Run focused contract tests plus required package/Apple integration checks for each actual change. Do not declare the full suite green without a verified complete run.

Open decisions:

| Decision | Proposed default | Required before |
| --- | --- | --- |
| Installation identity across reinstall/restore | Installation-scoped, no claim of permanent physical hardware identity | DeviceProfile persistence |
| Actor trust boundary | Trusted local caller context only; no remote/delegated actor protocol | Actor facade implementation |
| Membership/service authorization | Derive from existing signed scopes/capabilities; local restrictions only narrow | Scoped service handle |
| What counts as usable for automatic activation | Explicit eligibility calculation plus visible activation failure; exact criteria to review | Altering removal fallback behavior |
| Durable local enablement versus selected runtime | Keep distinct; preserve current selection behavior in first extraction | New service preference schema |
| Pending messages after leave/rejoin | Preserve data, forbid automatic cross-membership dispatch | Rebinding retained pending work |
| Policy updates and authority retirement | Inventory existing operations and specify individually; no generalized provider policy | Administration facade coverage |
| Physical module placement | Preserve package dependency direction; use existing targets first where coherent | Extracting reusable implementation |
| Profile schema, storage transaction and migration | Versioned records; existing IDs/data preserved; recover partial migration | Writing new persistent profiles |

No implementation is authorized merely by an unresolved table entry. This document is the review artifact; the first code slice should be separately scoped after its relevant decisions are settled.
