# Beakr Entity Design Discussion and Release 1 Next Steps

Discussion record • October 26, 2026

**Status: working design direction with unresolved implementation decisions.** This records the discussion through the Node control-point model, audit responsibility, checkpoint/restart, and beginning its application to R1. The user agreed with the allocation principle described in Section 3 and requested that this direction begin for R1. That supports bounded mapping and stabilization work; it does not settle identity, schema, or protocol changes. This supplements the [Entity Contract Template v1.1](Entity-Contract-Template-v1.1.md) and [Permissioned Networking Contract](Permissioned-Networking-Contract.md). It does not replace either document or claim that a v1.2 template has been created.

## 1. Objective and established constraints

The objective is to define entities precisely enough that responsibilities, permissions, operations, persistence, and lifecycle rules constrain where code changes are made. The user is learning the architecture; terminology and reasons for decisions must remain explicit.

The template organizes definitions as Meaning, Facts, Control, Behavior, and Lifetime. Each mutable fact has one responsible writer. Callers invoke restricted commands and observe read-only state. Relationships do not confer permission to mutate another entity directly. Contracts must be supported by implementation boundaries and tests; documentation alone cannot enforce them.

Existing enrollment coordinators, signed membership/capability checks, scoped credentials, and request-specific local authorization grants are foundations to reuse. No parallel trust system is authorized. Persistent configuration and unfinished durable work survive restart; connections and presence are reconstructed. Removing membership must not implicitly delete retained Context/message data.

No application code was changed during this design discussion. Existing staged, unstaged, untracked work and test data must be preserved.

## 2. Entity vocabulary and unresolved identity

The original networking proposal lists DeviceProfile, ServicesProfile, Actor, Network, NetworkMembership, ServiceBinding, PermissionGrant, NetworkSession, OperationRecord, and ContextRecord. These are logical concepts, not a requirement for a class or database table per name.

The later discussion proposes distinguishing User from Actor. That changes the earlier broad definition in which a person could be a kind of Actor; the documents have not yet been reconciled into an approved new model.

| Concept | Current proposed meaning | Unresolved boundary |
| --- | --- | --- |
| User | The person who requests or delegates work within their own authority. | Local versus cross-device identity, authentication, recovery, and removal. |
| Actor | An identified software participant through which a User requests or delegates work to Services. | Identity granularity, persistent representation, and how trusted caller context is established. |
| Device | The host on which Beakr operates and a home for appropriate local configuration. | Physical hardware versus application installation identity; restore/reinstall behavior. |
| Node | An identified logical control point that owns its side of protocol execution and the required evidence for work it admits and supervises. | Mapping to current network-specific NodeID, number of Nodes per Device/process, persistence, and isolation. |
| Service | Functionality providing useful operations through a restricted interface. | Identity, instances, inventory, enablement, lifecycle, inter-service calls, and bindings remain to be discussed. |

A Node now has a broader working conceptual meaning than a network participant alone. Nodes may be on the same machine or on different machines. Existing Beakr NodeID values remain network-specific; they must not silently be reinterpreted as new general execution identities. A Node ID does not prove who the User is. An Actor ID supplied in a payload does not establish authenticated Actor identity. Remote User/Actor authentication and delegation remain separate future designs.

The provisional Device contract can identify local preferences, profile loading/recovery state, and responsible writers without choosing a persistent Device ID yet. Device profile readiness must not imply network connectivity. Renaming, retirement, deletion, and advertised network names require distinct rules.

### Resolving the meaning of profile

The initial entity list mixed things being modeled with records describing those things. DeviceProfile and ServicesProfile appeared beside Actor and Network, suggesting that only some entities have persistent descriptions. That naming does not establish a storage requirement or a meaningful architectural distinction.

**Proposed definition:** a profile is a named, scoped grouping of descriptive attributes and desired configuration associated with an entity. It describes the entity; it is not the entity itself, its controller, or its complete state.

| Term | Meaning and boundary |
| --- | --- |
| Entity | The thing identified and governed by a contract, such as Device, Actor, Network, Node, or Service. |
| Profile | Descriptive attributes and desired configuration grouped for a defined purpose and scope. Its existence does not itself grant permission or prove identity. |
| Persistent record | A storage representation of durable facts. Profiles, operation journals, and audit entries can all have persistent representations; they are not all profiles. |
| Runtime state | Current execution and observation facts, such as loading, running, or connected. These are reconstructed rather than treated as persistent profile truth. |
| Policy or grant evidence | Rules and permissions with an identified issuer, scope, validity, and verification requirements. A reference from a profile does not turn local configuration into authority. |

For Beakr's local profiles, the proposed default is durable storage for descriptive attributes and desired settings. The contract must still specify storage and recovery; the word profile alone does not guarantee persistence. Read-only profile snapshots may be exposed without allowing callers to edit the underlying record.

A profile may refer to its subject by ID and to separately owned resources by reference. Referencing an identity or credential does not permit a profile editor to replace that identity or access secrets. Live presence, active connections, audit history, unfinished work, and authorization evidence retain their own owners and lifecycles even if presented together in the UI.

### Rules for introducing a profile

1. Start with the entity's Facts section. List the actual attributes and configuration needed; do not invent a profile merely to give every entity a matching name.
2. Group fields only when their purpose, scope, authority, responsible writer, and lifecycle are compatible. Separate fields with different owners rather than expose an unrestricted save-everything operation.
3. Specify the subject ID, cardinality, defaults, validation, read permissions, named change operations, revision rules where needed, persistence, migration, and removal behavior.
4. Treat a profile as a subordinate record by default. Give it a separate identity or independent lifecycle only when a concrete requirement justifies that choice.
5. Map the proposed grouping to current records before adding storage. A clearer conceptual name does not authorize an R1 type rename, schema migration, or duplicate repository.

### Application to the current terminology

| Current term | Interpretation and proposed treatment |
| --- | --- |
| DeviceProfile | Proposed local descriptive attributes and preferences. Device versus installation identity remains unresolved; no new ID or persistent schema is selected. |
| ServicesProfile | The proposal currently describes an inventory of configured services, not a profile for each Service. Describe it as a local service inventory in the discussion; its eventual type name and Service model remain open. |
| Actor | May need descriptive configuration and durable references to authorization. Define those needs first; ActorProfile is not yet required or specified. |
| Network | Has shared identity and authority-controlled policy/state. A member's local display preferences must remain distinguishable from verified shared facts; neither requires a new generic Network profile. |
| Node | The proposed control point has execution responsibilities; current network-specific identities and credential associations must be mapped explicitly. No additional NodeProfile store is justified solely for naming consistency. |
| Existing NetworkProfile type | Contains local Profile ID, Network ID, Node ID, display name, and creation date. It maps more closely to local participation/membership configuration than a complete shared Network description. Preserve its current code name and identifiers during R1. |

This resolves the vocabulary without requiring a profile for every entity: name the entity first, then define its profile only if a coherent grouping of facts is useful. Each entity contract must say whether such a grouping exists and how it maps to current code. This is a proposed documentation convention, not approval of the remaining entity schemas.

Every entity must have a coherent definition and set of facts. The optional question is whether a subset benefits from the name profile. Operation records, grants, and runtime sessions already have specific purposes; adding profiles merely for symmetry can obscure them. Use Attributes and configuration consistently in entity contracts and introduce a named profile only when useful.

## 3. Node as a logical protocol control point

The user described a Node as a logical locality and then more precisely as a control point that bounds protocol execution. Host and Co-Host are not introduced as technical entities. Their user-facing meanings remain separate; application instance, Service instance, and runtime coordinator can describe implementation responsibilities without introducing an ambiguous Host object. Existing code names containing Host are preserved.

**Working definition:** a Node is an identified logical control point that owns its side of protocol execution and produces attributable audit evidence for the work it admits and supervises.

| Template group | Node contract direction |
| --- | --- |
| Meaning | Bounds local protocol execution. Multiple Nodes may be on one machine; Nodes may communicate across machines. |
| Facts | Identifies controlled interactions, their local state, resource limits, pending work, and references to authorization and audit evidence. Persistence and identity schema remain undecided. |
| Control | Enforces admission, applicable permission/approval requirements, and execution limits. It does not invent rights or replace Service-level resource authorization. |
| Behavior | Coordinates protocol state progression, dispatch, outcomes, cancellation, required evidence, and safe recovery. A protocol instance has its own state; one state machine need not describe the entire Node. |
| Lifetime | Defines startup/reconstruction, admission shutdown, handling of running work, and recovery. Logical separation is not automatically process or security isolation. |

### Protocols and Services

A protocol is an interaction contract: participants, messages, interpretation, ordering, authorization, outcomes, limits, versions, and interruption rules. Each Node implements its own side. A state machine determines valid local progression; a transport carries communication. A Swift protocol declaration can express part of an interface but is not the complete behavioral contract.

```text
Actor requests work
        |
        v
Node admits and supervises the interaction
        |
        v
Service performs the permitted operation
```

Local protocols do not require a network connection. Being on the same machine does not remove authorization obligations. A rule's storage location, resource scope, execution locality, and network participation are distinct relationships. Node admission to an interaction does not authorize every application command it can carry.

### Node responsibility for the Actor audit trail

The Node is the responsible control point for required recording obligations; an audit repository owns durable storage. The Actor's history is a view of evidence attributed to it, not a log it controls. Services supply operation-specific outcome evidence that the Node cannot independently infer.

A Node records what it knows: acceptance is not remote execution, and a transport acknowledgement is not necessarily application completion. An Actor operating through several Nodes may have records from each; combining them requires trusted attribution and correlation rather than a matching claimed Actor ID. Protected alternative entry points must have equivalent enforcement and audit obligations or the history cannot be called complete.

Under the proposed audit-failure gate, the Node blocks affected protected work within its own scope and follows safe stopping/recovery rules. It cannot claim to stop the Actor everywhere. The exact mandatory gate and scope remain subject to the clarification in Section 7.

### File transfer with checkpoint restart

The agreed allocation principle is: **the Node ensures that an admitted interaction's execution requirements are satisfied; the protocol and Service contracts determine which mechanisms it provides, coordinates, or requires from another component.**

| Concern | Contract requirement | Node role |
| --- | --- | --- |
| Fragment/chunk size | Honor protocol bounds, receiver support, and local resource limits. | Supply and enforce applicable local constraints; never choose an incompatible size unilaterally. |
| Checkpoint recording | Record only progress that can safely be recovered under the storage contract. | Provide the facility or require it from the transfer implementation. |
| Recovery | Restore transfer identity and reconcile retained progress with the peer. | Coordinate resumption through the protocol; do not blindly repeat an uncertain completed action. |
| Integrity | Verify required fragments and completed content before reporting the corresponding success. | Ensure the responsible transfer component supplies the required result. |
| Audit | Attribute admission, interruption, resumption, and observed outcome. | Produce required evidence without treating it as the recovery checkpoint itself. |

A checkpoint answers what is needed to resume safely: transfer/content identity, verified retained ranges, and other protocol state. An audit record explains what happened and under whose authority. They may share identifiers but cannot substitute for each other. Required data and recovery metadata must be durable before progress is represented as safely recoverable.

Either the Node supplies checkpoint facilities while the transfer implementation defines their meaning, or the transfer Service owns checkpointing while the Node supervises its guarantees. If neither supplies durable restart support, the interaction is non-resumable and must be rejected when resumability is required. The Node must not grow into an implementation of every Service.

## 4. Proposed User and Actor relationship

The user proposed that Actor always mediate User requests to Services, with hands-on versus unattended work explaining the difference in operation. This is a design direction under exploration, not an implemented universal interface.

```text
User request or previously authorized trigger
                  |
                  v
        Trusted Actor context
                  |
                  v
       Restricted Service operation
```

Under the broader Node model, the Node bounds the relevant interaction even when its protocol is local. Network operations additionally require the appropriate binding, membership, and existing network identity. Which local operations must cross this boundary is a contract decision, not a claim that every function call needs a Node. Internal housekeeping still has explicit owners and need not be presented as a fresh User request for every internal step.

An Actor cannot grant itself rights. User delegation cannot override network policy, local restrictions, or resource/service authorization. Permission to transport a message is distinct from permission to execute a command contained in it.

Proposed starting cardinality: a User may authorize several Actors, with each Actor acting for one User. Shared Actors and further delegation are not assumed. This cardinality is a recommendation requiring review.

### Execution mode belongs to the work

| Mode | Proposed authorization basis |
| --- | --- |
| Hands-on | A request through trusted User interaction, subject to existing permissions and any required confirmation. |
| Unattended | Previously established authorization covering the activity's operations, resources, conditions, and duration. |

Mode does not grant permission. The recommendation is to associate execution mode and authorization basis with an invocation or activity rather than a single mutable mode on the Actor: interactive and previously authorized work could coexist.

Closing a window does not grant unattended authority. Already accepted work may finish according to its contract; additional work requires appropriate authorization. Withdrawal must define treatment of new, queued, and already executing work.

## 5. Authority and implementation ownership

Authority establishes rules within a scope. Permissions describe allowed actions. Authorization checks a particular request against trusted evidence. Ownership identifies the component that may change a fact.

For example, a local User may choose a friendly name, a controller validates and coordinates the change, and a repository saves it. The repository's ability to write bytes does not grant authority to choose the name. Network authority controls admission; local authority can stop local participation. Neither automatically controls deletion of retained information.

Each entity must specify the relevant authority by operation or fact. A single label such as “local authority” is insufficient. The proposed local profile is a Beakr-owned record; no Apple-managed configuration-profile mechanism or storage framework has been selected.

## 6. Auditability and accountable unattended work

The user identified a need to know what unattended Actors have done. Auditability is a proposed explicit contract requirement across both hands-on and unattended work.

| Record | Responsibility |
| --- | --- |
| Diagnostic log | Explain runtime behavior and failures to developers. |
| Operation record | Track and recover work, including unfinished procedures. |
| Audit record | Attribute requests, authorization decisions, and observed outcomes. |

These may share an Operation ID but have different retention and reliability requirements. Trusted authorization and execution boundaries should produce audit records; the Actor must not be the sole reporter of its own conduct.

Proposed audit fields include record ID, Actor and User references, Operation ID, Service/action/target, execution mode, authorization reference, decision/outcome, time and ordering information, and recording source. Routine records should exclude secrets and unnecessary payload content. Audit visibility, export, retention, deletion, and storage limits require policy.

Acceptance, execution, transport delivery, and remote processing must remain distinct outcomes. A protected local history is not automatically tamper-proof or proof of remote execution. Distributed completeness and stronger integrity guarantees require additional design.

## 7. Required auditing and express approval

**Unconfirmed interpretation:** the user wrote that if an audit “can be completed” the Actor must halt. The assistant interpreted this as “if required auditing cannot be completed, the Actor must halt.” That interpretation has not been explicitly confirmed and must not be recorded as an agreed requirement.

“Audit completed” must distinguish durable recording, completion of an operation's audit trail, and a human or automated review of that trail.

Under the proposed failure-gate interpretation, the controller blocks new protected work when required audit recording fails. Running work follows a documented safe stopping/recovery procedure. Abrupt termination is not automatically safe. If an external action happened but recording its outcome failed, recovery must preserve uncertainty and reconcile rather than blindly repeat the action.

The user also proposed express approval for some operations. Standing permission and request-specific approval are distinct. Approval should bind the Actor, operation, target, relevant parameters, approver, validity, and consumption/retry rules. Changed material parameters must not silently inherit an old approval. Reuse existing request-bound local authorization mechanisms where applicable.

```text
Request
  -> Check standing permission and state
  -> Obtain express approval if required
  -> Save required authorization/intent evidence
  -> Execute
  -> Record observed outcome
```

Open decisions include which operations require approval or durable audit gates, whether a block affects an operation/activity/Actor or a shared facility, who may resume work, and how resumption rechecks authority. Awaiting approval, audit failure, and recovery-required outcomes must remain distinguishable.

## 8. What a future template revision would add

| Template area | Proposed addition |
| --- | --- |
| Meaning | Identify which actions must be attributable and explainable. |
| Facts | Define profile groupings separately from entities, runtime state, and other persistent records; include audit provenance, correlation, and authorization references. |
| Control | Delegation scope where applicable; audit access; standing permission versus express approval. |
| Behavior | Protocol interaction contracts, Node control boundaries, audit obligations and execution gates; safe suspension, checkpoints, and uncertain outcomes. |
| Lifetime | Authorization withdrawal, audit retention, interrupted-work reconciliation, and resumption. |

User/Actor/Service-specific definitions belong in Beakr's entity contracts, not as universal requirements for every entity. Not every entity needs its own controller, journal, or state machine. Template v1.1 remains available unchanged for comparison.

## 9. Release 1 continues without a rewrite

The architectural discussion does not require replacing existing identities, stores, protocols, or coordinators. R1 remains stabilization work. The planning notes place consolidation of connectivity decision-making after R1 stabilization; controller extraction should not be introduced as a prerequisite to fixing current defects.

Preserve the single active application runtime, current IDs and storage, existing trust rules, Context retention, Device/Node terminology including Registered Devices, and the unresolved network-colour behavior. The colour-model decision remains an explicit review item before declaring R1 stable. Authority creation in the current application is Mac-only. Provider selection, generalized Actor execution, new User/Device inventories, and unattended approval/audit infrastructure are not added to R1 by this discussion.

### Validation baseline and its limits

The handoff reported a successful inspected Xcode build, focused state tests passing 5/5, and an earlier complete BeakrTests run with 36 passed and 9 failed in trust-dependent fixtures/state. Those results are historical, not a current pass claim. No builds or tests were run while saving this discussion.

Test names inspected in the current source include emptyRegistryCreatesNoNetworkSessions, switchNetworkAfterBootstrapFailure, configuredNetworkWithoutLocalNetworkIsInactive, and trustRecovery. Their presence is not evidence that they currently pass or cover every contract scenario.

### Recommended immediate R1 step

1. Re-establish the current BeakrTests baseline on a recorded Xcode scheme/destination, using isolated test storage and preserving Hamilton/Queens and all existing test data. Capture exact failing tests and diagnostics; do not assume the historical nine still fail.
2. Classify failures as product behavior, fixture defects, or environmental constraints. Fix the smallest demonstrated cause without weakening trust checks. Use focused reruns for repairs, then rerun the complete suite before reporting its status.
3. Map existing tests to activation, stopping, switching, removal/Context retention, stale completion, trust refresh, and restart behavior. Add only meaningful missing coverage. Contract scenarios C03/C04/C09/C10/C11/C14 are useful review anchors, not claims of existing coverage.
4. Perform the bounded Mac/iPhone Hamilton/Queens acceptance checks with preserved data. Review the network-colour semantics explicitly before changing them or declaring R1 stable. Keep platform limitations and skipped checks separate from product failures.

This is the next-work recommendation, not a claim that validation or repair has occurred.

## 10. Beginning this direction for R1

Begin by applying the ownership and interaction-contract discipline to existing R1 behavior, without creating a new generic Node runtime or permission schema. Mapping and characterization can proceed now. Changed behavior and extractions still require the relevant choices below to be settled. Stabilization remains the immediate implementation priority.

The first concrete trace is existing message submission: identify caller entry, selected membership, authorization checks, durable acceptance, dispatch, and observed outcome. This provides evidence for a Node responsibility map rather than assuming a new class must replace existing coordinators.

| Existing source inspected | Starting point for the responsibility map |
| --- | --- |
| Apps/Beakr/MessageComposerModel.swift | send(), HostMessagingService dependency, and OutgoingProvenanceMessagingService define existing submission seams. Provenance here must not be assumed to be a full Actor audit trail. |
| Apps/Beakr/ApplicationLANRuntimeManager.swift | start(), stop(), send(), sendWithProvenance(), and PersistentHostMessagingService provide lifecycle and delivery integration seams. |
| Packages/BeakrNet/Sources/BeakrNetTransfer/TransferProtocol.swift | Manifest chunk size/count, codec limits, and resume messages already exist. Reuse their semantics rather than inventing a competing fragmentation scheme. |
| Packages/BeakrNet/Sources/BeakrNetTransfer/TransferStagingStore.swift | Chunk validation, staging persistence, and retained progress provide an existing checkpoint/recovery seam. Source inspection is not a new durability or test-pass guarantee. |

The file-transfer example is an architecture test case, not a decision to add file-transfer UI to R1. The initial source mapping and documentation are complete; full behavior tracing and test verification remain next. Xcode read/test-discovery tools returned IDEKit.IDEStatefulActionError error 0 during this update. No test run occurred; the historical baseline above remains unchanged.

### Candidate code slice after characterization

Once R1 behavior and relevant choices are established, activation/stop ownership remains a candidate first extraction around existing models and storage. Settle target selection on failure, timing of stopping the prior runtime, restart behavior, and competing requests first. Do not silently change removal fallback from counting profiles to a new definition of usability.

If the purpose instead becomes demonstrating the new Actor model, its minimum credible slice is one trusted local User context, one Actor context, and one existing Service operation with enforced authorization and a defined audit outcome. Service and audit/approval boundaries must be decided first. No unattended scheduler, remote identity, or general delegation system is implied.

## 11. Open decisions for the next design conversation

| Decision | Why it matters |
| --- | --- |
| Meaning of audit completion and halt | Determines execution gates and safe recovery. |
| Service identity and operations | Establishes what Actors invoke and where enforcement lives. |
| Logical Node boundary and identity mapping | Defines controlled interactions without reinterpreting existing network NodeIDs or duplicating admission truth. |
| Protocol facility ownership | Assigns checkpointing, recovery, limits, and required evidence to existing components wherever possible. |
| User identity scope | Determines local attribution versus cross-device authentication. |
| Actor identity and cardinality | Determines independent permissions, cancellation, and retirement. |
| Device identity scope | Determines initialization, restore, reinstall, and deletion. |
| Profile contents and ownership per entity | Applies the proposed profile definition without introducing duplicate stores or silently renaming current code. |
| Delegation and approval lifetime | Determines expiry, withdrawal, pending work, and resumption. |
| Audit durability and visibility | Determines evidence guarantees, storage failure behavior, privacy, and retention. |

The next R1 action is validation and targeted repair, alongside tracing current message submission into a concrete control-point contract. The next architecture discussion is the Node/Service boundary and mandatory audit conditions. Neither requires a rewrite to begin.
