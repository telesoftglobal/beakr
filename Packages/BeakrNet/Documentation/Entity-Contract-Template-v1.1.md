# Entity Contract Template — Version 1.1

Beakr architecture discussion • October 26, 2026

**Version 1.1:** organizes the introductory vocabulary and reusable specification as Meaning, Facts, Control, Behavior, and Lifetime. Earlier unversioned documents are preserved.

**Status: proposed template for review.** This document explains a discipline for defining entities and assigning implementation responsibility. It does not approve a new API, persistence schema, permission system, or Release 2 implementation. Device identity remains unresolved until Device, Actor, and Node relationships are discussed.

## 1. What an entity contract defines

An entity represents something the system needs to distinguish and manage over time. Its contract defines what it means, what may be true about it, who may request changes, and how those changes happen.

An entity need not correspond to one Swift class or database table. Controllers and repositories manage entities; they are not necessarily attributes of those entities.

The reading and design order is **Meaning → Facts → Control → Behavior → Lifetime**. This is not a rigid implementation sequence; later decisions can require revisiting earlier ones.

### 1.1 Meaning — What is this entity?

Establish meaning and scope before describing behavior.

| Term | Meaning |
| --- | --- |
| Purpose | Why the entity exists and what it represents. |
| Boundary | What the entity is responsible for, and what belongs elsewhere. |
| Identity | What distinguishes this entity from another, and how long that identity lasts. |
| Relationships | Explicit associations with other entities, with their own rules. |

### 1.2 Facts — What is true about it?

Describe its facts, the rules they must satisfy, and their supporting evidence.

| Term | Meaning |
| --- | --- |
| Attributes | Facts describing the entity, such as a friendly name. |
| Configuration | Settings expressing intended behavior, including initial defaults. |
| State | Current facts, including configuration and runtime observations. |
| Status | A useful summary derived from selected state. |
| Invariant | A condition that must always remain true in valid state. |
| Revision | An identifier for a particular version of state, used to detect stale changes or observations under defined comparison rules. |
| Provenance | Where a fact or request came from, and the evidence supporting it. |

### 1.3 Control — Who controls it?

Separate the right to make a decision from the code responsible for carrying it out.

| Term | Meaning |
| --- | --- |
| Authority | Who is entitled to establish or change governing rules, including who may grant or withdraw permissions, within a defined scope. |
| Permissions | Which operations a particular caller may perform on a particular entity or resource, under specified conditions. |
| Authorization | The decision that a particular request has the required permission, based on trusted evidence. |
| Ownership | Which implementation component is responsible for changing each fact. This differs from authority to approve a change. |

### 1.4 Behavior — How may it change?

Describe requests, permitted changes, and observable outcomes. Events may also trigger subsequent transitions.

| Term | Meaning |
| --- | --- |
| Operations | Named requests to inspect or change the entity. |
| Precondition | Something that must be true before an operation may proceed, beyond permission alone. |
| Transition | A permitted change from one state to another, triggered by a command or event. |
| Postcondition | What must be true when an operation reports a particular outcome, such as accepted or completed. |
| Failure contract | Defined outcomes when an operation cannot complete, including partial completion and recovery responsibilities. |
| Event | A report that something happened, with an identified source and scope. |

### 1.5 Lifetime — How does it endure over time?

Describe existence across operations, interruptions, and restarts.

| Term | Meaning |
| --- | --- |
| Lifecycle | Rules governing creation, use, recovery, retirement, and deletion. |
| Persistence and recovery | What survives interruption and how consistent state is restored. |

Attributes and configuration contribute to state; status summarizes it. These concepts do not require separate containers that duplicate values.

State answers “What is true now?” Lifecycle answers “How may those facts change over time?” Status answers “How do we summarize the relevant facts?”

These groups include both the entity's facts and the rules governing it. Authority establishes the rules; permissions express allowed actions; authorization checks a particular request. Ownership identifies the component that performs the permitted change.

Not every entity needs its own persistent revision or independent state machine. State explicitly when a concept does not apply. Timeouts, cancellation, retries, duplicate handling, resource limits, and compatibility belong in the relevant operation and persistence contracts.

## 2. Classify state and name its owner

| State category | Example | Rule |
| --- | --- | --- |
| Durable | Saved friendly name or user preference | Survives restart through an identified repository. |
| Runtime | A profile is currently loading | Reconstructed during execution. |
| Derived | Whether an operation is currently available | Calculated from authoritative facts and permissions. |

Each mutable fact has one responsible writer. A derived value must not become a second independently editable source of truth. Saved defaults are applied during initialization or an explicit migration, not reapplied on every launch.

Independent dimensions stay separate. For example, a membership may simultaneously be admitted, locally disabled, and disconnected. “Recovery required” must not erase what is known about admission.

---

## 3. Define ordered transitions

A state machine specifies permitted transitions: current state, command or event, required conditions, next state, and effects. It also specifies rejection, repeated requests, and stale events.

The following example describes profile loading only. It is not a complete Device lifecycle or an approved implementation.

```text
Not loaded
    | load requested
    v
Loading
    |-- valid profile loaded --> Ready
    |-- load/validation failed -> Recovery required
```

| Current state | Command or event | Condition | Next state / effect |
| --- | --- | --- | --- |
| Not loaded | Load requested | Trusted bootstrap caller | Loading; request repository read. |
| Loading | Load succeeded | Current attempt; valid record | Ready; publish loaded profile. |
| Loading | Load failed | Current attempt | Recovery required; publish safe failure. |
| Ready | Load requested | Already loaded | Ready; return current state. |
| Recovery required | Retry requested | Retry permitted | Loading; start a new attempt. |
| Any | Old attempt completes | Attempt was superseded | Ignore result; do not overwrite current state. |

Not every attribute change requires a new lifecycle state. Renaming an entity may leave it Ready while changing its saved name.

## 4. Separate decisions from effects

A transition function takes current state and a validated command/event, and returns a decision: next state and required effects. It does not itself read files or open connections.

The controller performs effects, then feeds their outcomes back as events. For a proposed rename operation:

```text
Request -> Check permission and input -> Request save
        -> Receive save outcome -> Publish committed state or failure
```

Required persistence must succeed before committed success is reported. If the UI displays a provisional edit, it must remain distinguishable from saved state.

### Ordering while asynchronous work runs

The contract must say whether overlapping operations queue, conflict, or supersede one another. Serialize state decisions and use operation IDs, generations, or expected revisions where needed. A late result from a superseded load or stopped runtime must not restore old state.

Swift actor isolation can help protect access, but execution can interleave across await points. Recheck relevant state when work resumes. Cross-entity procedures may require coordination beyond a single entity's controller.

---

## 5. Specify permissions and operations together

Permission is necessary, but an operation must also be valid for the entity's current state. Permission to rename does not guarantee that storage is available to save the change.

The policy owner establishes rights. The operation controller enforces them. Knowing how to perform an action does not authorize the controller or its caller to perform it.

Authority must be specified by scope, rather than as a vague single label such as “local.” A network authority controls admission; the local user can stop local participation. Neither action automatically authorizes deleting retained messages. A controller may be the sole writer without being entitled to establish the policy it enforces.

Provenance determines how a fact may be used. A claim of admission in an incoming payload is not equivalent to verified authority evidence. Neither an event nor a revision number establishes trust by itself. Define revision scope and comparison rules; do not assume revisions from different entities are comparable or that a newer claimed revision is authentic.

| Operation contract field | What to specify |
| --- | --- |
| Caller and target | Trusted caller provenance and explicit target IDs. |
| Permission | Required rights, their scope, and their authoritative evidence. |
| Input | Valid values, bounds, and any expected revision. |
| Preconditions | States in which the operation may execute. |
| Invariants and postconditions | Rules that remain true and the guarantees associated with each reported outcome. |
| Transition and effects | What changes, which owner changes it, and in what order. |
| Persistence | What must be saved before acceptance or completion. |
| Outcome | Exact meanings of accepted, completed, blocked, and failed. |
| Failure contract | Typed failures, partial effects, uncertain remote outcomes, and the owner of recovery. |
| Retry and interruption | Idempotency, cancellation, stale results, and restart recovery. |
| Observation | Scoped state updates and safe diagnostic events. |
| Verification | Success, denial, invalid state, concurrency, and recovery tests. |

CRUD means create, read, update, and delete. These are useful storage operations, but public commands should express intent: for example, renameDevice rather than an unrestricted modifyDevice. Observers receive read-only snapshots, not arbitrary setters.

UI controls can reflect permission, but hiding or disabling a button does not replace enforcement at the command boundary. Reads and observations can also require permission.

For Beakr, reuse existing signed membership/capability evidence, scoped credentials, and request-specific local authorization. This template does not introduce a parallel trust system. A local Actor ID alone is not authentication or permission.

## 6. Give each implementation component a boundary

| Component | Responsibility |
| --- | --- |
| Restricted command interface | Exposes permitted requests without exposing arbitrary mutation. |
| Controller/coordinator | Checks authorization and coordinates transitions and effects. |
| Transition rules | Determine valid changes and required effects. |
| Repository | Loads and saves durable records; does not decide caller authority. |
| Effect adapter | Performs platform or external interactions. |
| Read-only snapshot | Presents current facts to authorized observers. |

These are logical responsibilities. They do not require a separate class or module for every row. Restricted interfaces constrain trusted code; they do not isolate hostile code in the same process.

---

## 7. Define relationships explicitly

Use typed IDs to reference other entities. A reference establishes which entity is involved; it does not grant permission to inspect or change it.

| Relationship field | Required definition |
| --- | --- |
| Meaning and endpoints | What is associated, and why? |
| Cardinality | One-to-one, one-to-many, optional, or another explicit constraint? |
| Owner | Who may create, change, or remove the association? |
| Validity | What must be true about both endpoints? |
| Persistence | Is the relationship saved or reconstructed? |
| Removal behavior | What happens if either endpoint is retired or deleted? |
| Authorization | Who may establish, inspect, or use the association? |
| Recovery | What happens if an endpoint is missing or a multi-step change is interrupted? |

Example: a proposed ServiceBinding refers to one local service instance and one NetworkMembership. Its contract must still say whether it may exist while admission is pending, how forgetting membership affects it, and what happens to pending work.

Where practical, save an association once and derive reverse lookups. Independently editable lists on both sides create competing truth.

### Relationships do not confer mutation rights

A membership removal coordinator may request Context detachment through the Context owner's interface. It must not directly delete Context records. Retained information has its own lifecycle.

For procedures spanning owners, document the ordered requests and recovery after partial completion. Files, protected credentials, and remote state are not one atomic transaction. Reuse existing durable operation records when they already cover the procedure.

## 8. Define the lifecycle, including recovery

For every entity, specify creation, validation, usability, ordinary changes, recovery, retirement, and deletion where applicable. Some entities are immutable; some are derived views and have no independent persistent lifecycle.

Retirement means the entity stops participating or accepting work. Deletion means specified records are removed. These are not automatically the same operation.

State which relationships and retained information survive each action. For Beakr, forgetting membership must not implicitly delete retained Context/message data or silently authorize pending work under another membership.

On restart, restore durable facts and unfinished procedures. Reconstruct runtime facts. Missing credentials or damaged records must produce defined recovery behavior, not silent replacement identities or empty stores.

---

## 9. Reusable entity specification

Use the following outline for each entity in the Permissioned Networking Contract. Keep unresolved decisions explicit; a blank or proposed entry does not authorize implementation.

Follow the same five groups as Section 1, then record verification and unresolved decisions.

### 9.1 Meaning — What is this entity?

| Section | Required content |
| --- | --- |
| Purpose and boundary | What the entity represents, why it exists, and what responsibilities belong elsewhere. |
| Identity | ID type, uniqueness scope, creation, lifetime, and restore/reinstall rules where relevant. |
| Relationships | Endpoints, cardinality, owner, validity, removal, and recovery rules. |

### 9.2 Facts — What is true about it?

| Section | Required content |
| --- | --- |
| State dictionary | Each attribute and configuration value: meaning, type, default, durable/runtime/derived classification, and writer. Define how status is derived. |
| Invariants | Conditions that must always hold in valid state. |
| Revisions | Version scope, comparison rules, and detection of stale changes or observations. |
| Provenance | Sources of facts and requests, supporting evidence, verification, and freshness requirements. |

### 9.3 Control — Who controls it?

| Section | Required content |
| --- | --- |
| Authority and permissions | Who may establish rules or grant/withdraw rights for each scope; permitted callers, operations, resources, and conditions. |
| Authorization | Enforcement points, trusted caller establishment, and evidence required for a particular request. |
| Ownership | Responsible writer for each fact; actual interfaces, components, modules, and files once selected. |

### 9.4 Behavior — How may it change?

| Section | Required content |
| --- | --- |
| Operations | Named commands and their individual contracts. |
| Preconditions | Required starting conditions beyond permission alone. |
| Transition table | Current state, trigger, conditions, next state, effects, and invalid/stale cases. |
| Postconditions | Guarantees for every reported outcome, including acceptance and completion. |
| Failure contract | Denied, blocked, failed, partial, or uncertain outcomes; recovery ownership. |
| Events | Event sources, observation scope, relationship to revisions, and duplicate or stale-result handling. |

### 9.5 Lifetime — How does it endure over time?

| Section | Required content |
| --- | --- |
| Lifecycle | Creation through retirement/deletion; retained information and restart behavior. |
| Persistence and recovery | Repository owner, schema/version, commit boundaries, and interrupted-work recovery. |

### 9.6 Review and verification — Applies to every group

| Section | Required content |
| --- | --- |
| Acceptance scenarios | Observable success, denial, failure, concurrency, and recovery behavior. |
| Open decisions | What remains undecided and which implementation work it blocks. Explicitly identify concepts that do not apply. |

## 10. Use the contract to control code changes

| Intended change | Expected home |
| --- | --- |
| Add or change an operation | Command interface and operation contract. |
| Change permitted transitions | Transition rules and relevant tests. |
| Change permission requirements | Authorization policy and enforcement boundary. |
| Change saved fields or format | Record schema, repository, and migration. |
| Change relationship behavior | Relationship contract and responsible coordinator. |
| Change external interaction | Effect adapter. |
| Change presentation | UI consuming read-only state. |

For each future change, identify the affected contract rule, responsible owner, allowed implementation locations, and verification evidence. If no owner exists, resolve that design gap before adding mutation elsewhere.

Documentation alone cannot guarantee placement. Access control, restricted interfaces, dependency boundaries, review, and meaningful tests must support it. Preserve Beakr's existing package dependency direction: application features may depend on networking; networking must not depend on application features.

**Next discussion:** apply this template to one entity before extending it to all proposed entities. Device versus installation identity remains open; Actor and Node definitions will inform that decision. No application code is changed by this document.
