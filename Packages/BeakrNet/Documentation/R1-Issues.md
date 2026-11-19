# R1 Issues and Deferred Work

Recorded November 8, 2026, at the user's request.

R1 is complete and accepted within its documented scope as of November 7, 2026. This register captures larger work outside R1, smaller follow-ups, and accepted evidence limitations. “Issues” does not mean that every entry is a defect or an outstanding R1 acceptance requirement. Recording an item does not authorize implementation or assign it to a release.

The existing networking foundations and the integrated Beakr application have different scopes. Several package capabilities already exist even where their application-facing workflows remain deferred. Preserve those foundations rather than treating this register as a request for a rewrite.

## Larger architecture and implementation work

All entries below remain future design/integration work at the scope described. Existing components are noted to prevent overstating what is missing.

| ID | Area | Existing foundation | Work outside the accepted R1 scope |
| --- | --- | --- | --- |
| R1-F01 | Unified state machines and lifecycle ownership | Enrollment, discovery and authority hosting already have stateful machinery, cancellation and generation checks. | Consolidate application connectivity decisions into authoritative reducers with explicit events, transitions and effects. Define coherent ownership and consistent UI consumption rather than adding state machines from scratch. |
| R1-F02 | Integrated performance metrics | Console traces, delivery diagnostics, bounded runtime counts and acceptance-time resource observations. | Integrate latency, throughput, queue depth/age, retries, reconnects, delivery time and resource pressure into a permissioned monitoring system with history and diagnostics. Define units, measurement boundaries, freshness, retention and sampling cost. |
| R1-F03 | Connection-quality monitoring | Authenticated connections, peer updates and periodic network-information reports. | Add the proposed authenticated “sonar” request/reply check, optional monitoring, per-peer rolling baselines and a heatbar/heatline. Existing updates are not timed health checks. Distinguish responsiveness from radio strength, raw packet loss and connection presence. |
| R1-F04 | Concurrent network participation | Multiple saved memberships and independently running Mac authorities. | Support messaging and authenticated presence observation on several networks simultaneously. R1 gives one selected network the app's messaging/presence runtime. Define isolation, lifecycle, resource budgets and platform execution limits first. |
| R1-F05 | Host/Co-Host service roles | Independent authority hosting, separate from messaging participation. | Define role permissions, responsibilities, coordination, persistence and failure behavior. Independent authority hosting does not implement the broader service-role model. |
| R1-F06 | General Node/Service control model | Existing coordinators, service contracts, queues, checkpoints and admission boundaries. | Formalize which component admits work, supervises execution, enforces limits, owns recovery requirements and reports outcomes. The proposed logical Node model is not yet a general execution framework. |
| R1-F07 | User/Actor permissions and delegation | Node credentials, service scopes, membership checks and existing local authorization mechanisms. | Establish trusted caller identities, operation/resource-specific grants, delegation, expiry, withdrawal and interactive versus unattended authorization. Current network membership is not the complete Actor permission model. |
| R1-F08 | Accountable execution and audit | Diagnostic logs, message provenance and operation-specific persistence. | Define durable attributable records of requests, permission decisions, approvals and outcomes; mandatory audit gates; and recovery from uncertain outcomes. Clarify the proposed audit-failure “halt” rule before treating it as a requirement. Diagnostics are not a complete Actor audit trail. |
| R1-F09 | Permissioned remote administration | Local authority administration and protocol/authorization foundations. | Inspect and configure another node through authorized commands with version checks, idempotency, recoverable results, rollback and required local consent. Local authority administration alone does not provide this system. |
| R1-F10 | Dynamic logical channels and shared state | Control, Data and Blackboard semantic channels and package implementations. | Define application-facing creation, joining, subscription, closure and coexistence of logical conversations/shared-state exchanges, with their own permissions and lifecycle. Avoid inventing competing identities without mapping existing abstractions. |
| R1-F11 | Application-facing file transfer and Blackboard workflows | Durable transfer, resumable staging, Blackboard repositories and replication components exist at package level. | Add file-transfer UI, product-specific shared repositories, subscriptions, conflict presentation and workflows. Reuse existing protocols and persistence; package completion does not establish complete product integration. |
| R1-F12 | Relay, mesh and additional transports | Relay and transport-handoff foundations exist; R1 app acceptance centers on authenticated LAN messaging. | Integrate authorized forwarding, durable relay custody, route selection, multi-hop/federation and explicit cross-network forwarding where required. WatchConnectivity, BLE, Wi-Fi Aware and live-media transport remain separate decision-gated projects. |
| R1-F13 | Authority-managed capabilities and providers | Current fixed services/security behavior and connection capability checks. | Define configurable service policy, encryption/compression provider contracts, compatibility negotiation, downgrade rules, trust requirements and administration. Network policy, installed capability and negotiated configuration must remain distinct. |
| R1-F14 | Operational deployment and management | BeakrNetOperations supplies supporting configuration, custody, telemetry, backup and recovery contracts/tests. | Supply actual deployment adapters, key-custody arrangements, monitoring dashboards, backup/restore operations and operational recovery procedures. Package contracts do not by themselves constitute an operated production service. |

## Smaller product and tooling follow-ups

These are recorded follow-ups or unresolved design choices, not newly discovered failures or additional R1 gates.

| ID | Follow-up | Scope and qualification |
| --- | --- | --- |
| R1-F15 | Authority hosting-state visibility | Show Running/Stopped through the network-row authority icon, potentially with a slash for Stopped, and consider read-only status in View Parameters. Distinguish starting/failure and local hosting from remote reachability. Exact presentation remains to be designed. |
| R1-F16 | Network-health colours | Reconsider whether local network health should be represented independently of authenticated peer counts. Retain the accepted R1 semantics until an explicit product decision and coordinated implementation. Older roadmap wording is not a reason to reopen completed R1 signoff. |
| R1-F17 | Authority-state change notifications | Add authenticated advisory invalidation and generation comparison, followed by verified signed-state refresh before applying changes. Periodic refresh remains a fallback. Historical planning places this after R3; this register makes no new scheduling commitment. |
| R1-F18 | Network diagnostics and Wi-Fi-name presentation | Refine physical-network identification, Connection Info and relevant settings access. Earlier notes describe prepared/disabled Wi-Fi-name support and provisioning requirements; verify current entitlement/build status before implementation rather than assuming it remains unchanged. |
| R1-F19 | Mac window-placement refinements | Improve Network Parameters opening position, height and scrolling behavior relative to the parent window/sidebar and visible display. This is separate from the accepted Settings navigation/editor fixes. |
| R1-F20 | Device Hub keyboard shortcuts | Track Command-A/Command-V behavior separately from native simulator selection/copy/paste and Mac clipboard-to-native-Paste checks, which passed. Do not conflate this tooling issue with network delivery. |

## Accepted R1 evidence limitations

These entries describe limits of verification, not proof that an implementation is missing or defective. The user explicitly accepted the relevant scope/dispositions before final R1 signoff. Preserve historical failures, fixes and retests; do not turn an unperformed variant into a PASS or repeat passed checks without a specific reason.

| Evidence area | Retained limitation |
| --- | --- |
| E1 / E3: trust and outage behavior | No complete live trust-freshness-boundary run or correlated signed-refresh/retry trace. Existing startup/outage/recovery and controlled-regression evidence was accepted. |
| E2: unknown-member recovery | Live post-recovery membership generation/admission was not captured in the same run; debugger pauses limit timing claims. Complementary live and isolated integration evidence was accepted. |
| E6: resource behavior | No instrumented resource trend across repeated lifecycle cycles or complete Swift task inventory. Earlier High energy reading remains unexplained. Functional cycles and bounded idle observations were accepted. |
| E11: impaired communication | No Beakr TCP retransmission/message-ID trace. The live host outage affected both authority and messaging rather than independently filtering authority HTTPS. Configured impairment/recovery and fixture evidence was accepted. |
| E9: revoked-credential rejection | No live receiver capture of a presented old credential being rejected. Production security code was exercised through test-controlled connections, scheduling and storage integration; those fixture boundaries remain explicit. |
| E13: creation | Clean-Mac first creation and creation-failure UI/runtime variants were not run because no spare Mac/test account was available. Existing live additional-network creation and isolated first-create/rollback cases were accepted. |
| Independent hosting | Delayed administration after selection changes and occupied-port/startup-failure UI scenarios lack full live UI verification. The live authority-continuity result does not provide exhaustive interruption timing or client signed-generation capture. |
| E14: Friendly Name | Inactive-save/normal-startup isolated coverage was accepted in place of an unavailable live editor-off route. Platform foreground checks and the physical-iPhone background variant do not establish every lifecycle interleaving. |
| Final validation and inventory | Final Mac, physical-iPhone and original-simulator builds, loaded-library identities and startup preservation were verified. This was not a new full-suite or final-build roundtrip exercise. Source/config and binary fingerprints have documented exclusions; excluded devices were not certified. |
| Historical requirements | The original A-Series checklist was unavailable. Acceptance concerns the documented R1 scope, not requirements inferred from case labels. |

## Suggested starting point — not an approved implementation plan

Consider **state ownership and observability together** (R1-F01–F03): define authoritative transitions and emit structured measurements from those transitions. This could give subsequent multi-network participation, permissions and service work a more dependable foundation.

This ordering is a recommendation. Before implementation, select one bounded increment, map existing owners/components, define its behavior and measurement contract, and identify validation that adds evidence rather than repeating passed R1 checks. Recording this list does not start that work or establish a release date.

## Next Steps

- Latest, November 9 16:48: bounded foreground status monitoring implemented; 19 new monitoring cases and 12 existing regressions pass, plus Mac/iPhone builds. No live monitoring/UI result yet. Next separately authorized phase is a user-operated visual/foreground exchange after fresh environment and loaded-build checks. See Shared-Status-Subscription-Design-2026-11-09.md for implementation, build UUIDs and exact evidence. Accepted R1 and one-shot permission-lifetime work remain closed.

- Latest design phase, November 9: foreground peer-status subscription proposal is documented in Shared-Status-Subscription-Design-2026-11-09.md. Read-only design review complete; no implementation or live testing started. Review its fixed limits, separate permission, explicit reconnect Start and acceptance criteria before authorizing one bounded implementation. Accepted R1 and permission-lifetime work remain closed.

- Latest acceptance, November 9: user accepted the bounded permission-lifetime increment after the PL-1 correction. PL-1 is closed under the documented response commitment boundary and evidence limits. No further work or live testing is pending for this increment; choose any next product capability separately. Earlier recommendations and holds below are historical. R1 remains accepted.

- Latest, November 9 16:30: PL-1 reproduced, corrected with an actor-serialized response commitment boundary, and verified by three new tests plus five regressions. Baseline/Mac/iPhone builds pass. The increment is recommended ready for user acceptance with its explicit in-flight-response limitation; no new live testing is requested. Earlier closeout hold below is historical. See the final PL-1 section in Shared-Status-Shortcuts-2026-11-08.md.

- Closeout review, November 9: hold final acceptance of the permission-lifetime increment for PL-1, a possible withdrawal/final-submission race identified by source inspection. Next bounded work is to define and prove the response commit boundary with a deterministic fixture, then correct ordering if needed. No code or live tests were run in this review; earlier workflow evidence and R1 acceptance remain valid. Full finding: Shared-Status-Shortcuts-2026-11-08.md, latest closeout section.

- November 9 latest: user confirms Shortcut success and sharing selection retained across app restart and XYZ ↔ E8-Test switching. These observations are user-confirmed, without new loaded-build or console correlation. Offline enablement correction has six passing focused tests and baseline/Mac/iPhone builds; user now confirms offline Off → On retention on the verified corrected Mac build (PID48012 / image43D880E6-1DE9-30FB-ADEA-8CE5976500AC). User also confirms the subsequent iPhone Shortcut succeeds and the Mac sharing control remains On. The bounded offline-enable/reconnect check is complete as user-confirmed evidence, without a new request-log correlation. Do not repeat the reported successful restart/switch checks. Before any new live phase, reconfirm environment and verify the loaded build. R1 acceptance is unchanged. See Shared-Status-Shortcuts-2026-11-08.md for exact scope.

### November 8 progress update

The first lifecycle-observability increment and bounded user-operated Mac startup/Refresh trace are recorded in the latest handoff. The [restricted shared status service](Shared-Status-Service-Proof-2026-11-08.md) has progressed from its isolated proof (26 distinct cases) to selected-runtime integration (ten distinct new integration scenarios). Remote-device details now offer sharing, default off for each admitted peer connection, and an explicit Request Status action. The authenticated receive adapter keeps status separate from durable chat and invalidates access on lifecycle/trust changes; recovered trust requires a fresh sharing choice even if the registry route is unchanged. Simulator, Mac and physical-iPhone builds pass. A separately authorized November 8 live exchange now confirms default denial, an explicitly allowed Mac snapshot on iPhone, and subsequent denial, using verified console sessions and supplied screenshots. This is bounded interoperability evidence, not a full accessibility audit or performance benchmark. A subsequently authorized UI increment adds a Shared Status menu popover on Mac and bottom sheet on iPhone, retaining the inline section and shared state with clearer directional wording. Both builds pass; the new presentation is not yet visually verified. A narrow DataDispatcher retry correction accompanied the earlier proof. Read the linked contract/evidence before choosing another bounded phase; the general Actor model and Siri/AI remain deferred. The original recommended sequence below remains historical guidance, not authorization for additional phases.

Recorded November 8, 2026. Begin with **state ownership and lightweight observability**, then prove a small information-exchange service. This strengthens the foundation without prematurely committing to a general Actor framework, mesh network or AI integration.

The following handoff can be pasted into a new conversation. It records a recommended sequence, not authorization to implement every phase.

### New-conversation handoff

Resume Beakr in `/Users/ice-9/Documents/_Projects/Beakr`.

This is an exploratory project. The goal is a stable, understandable foundation for moving information across a personal network, eventually supporting Siri/AI-assisted analysis and authorized actions.

### Current status

R1 was accepted November 7, 2026, within its documented scope and explicitly approved evidence limitations. Do not reopen accepted checks without a specific regression or new requirement.

Implemented foundations include authenticated LAN messaging, durable queues and duplicate suppression, network-specific identities and memberships, trust maintenance, independent Mac authority hosting, and authenticated dynamic authority endpoint discovery.

Each app currently selects **one network for messaging and presence observation**. Multiple saved networks and concurrently hosted authorities do not imply simultaneous messaging. Host/Co-Host service roles remain future design work.

Read:

- `HANDOFF-2026-10-29.txt`
- `Packages/BeakrNet/Documentation/R1-Issues.md`
- `Packages/BeakrNet/Documentation/Beakr-Network-Architecture-and-Operations-2026-11-07.md`
- `Packages/BeakrNet/Documentation/R1-Signoff-Audit-2026-11-01.md`
- `Packages/BeakrNet/Documentation/Beakr-Product-Goals.md`
- `Packages/BeakrNet/Documentation/Permissioned-Networking-Contract.md`

Consult the latest acceptance entries and relevant source when needed. Older documents contain proposals and superseded implementation descriptions; distinguish those from current behavior.

### Recommended direction

1. **Map state ownership before refactoring.** Identify the owners of membership/admission, local intent, runtime lifecycle, connectivity, authority hosting, peer presence and UI selection. Document transitions, side effects, persistence and cancellation. Existing state machines and coordinators should be reused; do not assume a new universal state machine is needed.

2. **Instrument one bounded lifecycle path.** Start with selected-network startup, peer connection and recovery. Define structured events and measurements for transition duration, failure reason, retries and pending work. Distinguish unavailable or stale measurements from zero. Keep sampling bounded and exclude message contents and secrets. Begin with developer-readable diagnostics; a dashboard can follow demonstrated needs.

3. **Prove one small information service.** After the first increment is stable, choose an explicitly authorized, read-only request/reply use case—for example, an iPhone requesting a bounded structured information snapshot from a Mac. Reuse existing Data, correlation, persistence and authorization facilities. Specify provenance, freshness, size limits, cancellation, offline behavior and observed outcomes. No arbitrary remote shell or unrestricted file access.

4. **Establish the minimum permission boundary for that service.** Separate permission to transport a request from permission to read the requested information. Define requester, target, operation, resource scope and evidence of the result. Let this concrete case inform the broader User/Actor/Service model rather than building that entire framework first.

5. **Add Siri/AI as callers of the same restricted service boundary.** Once deterministic service behavior is established, integrate a narrow assistant entry point. AI-generated requests must use the same validation and authorization as other callers. Separate information retrieval and analysis from commands that change state or disclose information.

Concurrent networks, dynamic channels, relay/mesh, Host/Co-Host roles, broad delegation and richer monitoring remain candidates to introduce when a concrete scenario requires them. Package-level Blackboard, transfer and operations foundations already exist; audit and reuse them before proposing replacements.

This sequence is a recommendation for discussion, not authorization to implement every phase.

### Working constraints

- Preserve all workspace and staging changes. Do not reset, stage or commit.
- Guide me one bounded phase at a time.
- Never touch iPhone 18 Pro; it preserves archived XYZ history.
- Preserve XYZ identities/memberships and R1-E8-Test/R1-E2-Test profiles/history.
- No live-membership revocation, profile deletion, re-enrollment or simulator resets.
- Automated app interactions only on `Beakr-R1-Contract-Baseline-20261026`, UUID `E40CDB24-C697-4F57-8F87-CBFD9DFADDD5`.
- Physical iPhone, Mac and other simulator interactions are user-operated.
- Use Xcode `BuildProject` for agent app builds.
- Explicitly verify console platform/session/PID; console retrieval has returned the wrong platform before.
- Reconfirm Network Link Conditioner and hosting state before new live testing.
- No backwards compatibility is required.
- Do not repeat passed tests without a specific reason.

Last confirmed state, November 7: Mac, physical iPhone-Dev and original iPhone 17/iOS 27.0 used XYZ and were green; original identities, names and history were preserved. Mac XYZ authority was Running and E8 authority Stopped. Treat this as historical until reconfirmed.

### Start here

Perform a read-only assessment of current state ownership and existing instrumentation. Recommend the smallest useful first increment, with its purpose, affected components, acceptance criteria and explicit exclusions. Do not begin a broad rewrite or device testing.

## References

- [R1 signoff audit](R1-Signoff-Audit-2026-11-01.md): final acceptance and evidence dispositions.
- [R1 adverse-condition acceptance](R1-Adverse-Conditions-Acceptance.md): detailed execution history and limitations.
- [Beakr network architecture and operations](Beakr-Network-Architecture-and-Operations-2026-11-07.md): implemented R1 overview.
- [Next milestones](Next-Milestones.md): existing roadmap and smaller follow-ups; distinguish historical statements from later accepted results.
- [Permissioned networking contract](Permissioned-Networking-Contract.md): proposed state reducers, entity ownership and restricted interfaces.
- [Entity design discussion](Entity-Design-Discussion-2026-10-26.md): Node/Service boundaries, User/Actor model, audit and approval questions.
- [Node, identity and routing principles](Node-Identity-Routing-and-Relay-Principles-2026-10-30.md): multi-network goals, channels, remote administration, grants and observability.
- [Network identification and connection diagnostics](Network-Identification-and-Connection-Diagnostics-2026-10-28.md): sonar checks, rolling measurements and presentation proposals.
- [Authority-managed capabilities](Authority-Managed-Network-Capabilities.md): future network policy and providers.
- [Production operations design](Production-Operations-Design.md): existing package contracts and deployment boundaries.

### November 8 — foreground Shortcuts caller

Following separate assessment and authorization, Request Device Status now wraps the existing selected-runtime status service with stable network/node target identity, foreground/main-app execution and local device authentication. Eight adapter tests and Mac/iOS builds pass; live Shortcuts discovery/execution is unverified. No sharing-change or network-switch capability is exposed. See [scope and evidence](Shared-Status-Shortcuts-2026-11-08.md). This is not general Siri/AI delegation and does not reopen R1.

### November 8 — Shortcuts case parked

Action discovery, device selection and foreground execution reached a responder denial. Ordinary iPhone backgrounding destroys the connection-scoped sharing permission, preventing the intended allowed Shortcuts workflow across reconnection. User asked to set the case aside until tomorrow. See the [parked case and proposed permission-lifetime design](Shared-Status-Shortcuts-2026-11-08.md#parked-connection-scoped-permission-conflicts-with-shortcuts). Persistent per-peer intent is proposed only; no permission behavior changed. Resume with design/credential-lifetime review; live acceptance remains incomplete and R1 stays accepted.


### November 9 — persistent Shared Status permission lifetime

Following explicit implementation authorization, sharing intent is saved per local profile/network/node, remote node and fixed status-read operation, with credential/key and authority pinning. Ordinary disconnect preserves intent while capabilities and pending work end. Offline withdrawal and failed-write/interrupted-session recovery are implemented. Twenty-five new fixture cases and one changed-runtime regression passed; baseline iOS, Mac and physical-iPhone builds passed. No new live tests: successful authorized Shortcuts execution and the changed UI remain unverified. See [current contract and evidence](Shared-Status-Shortcuts-2026-11-08.md#november-9-persistent-permission-lifetime-implemented). R1 remains accepted. Future subscriptions, monitoring and remote configuration recorded in Product Goals do not expand this increment.


### November 9 live permission-lifetime result

The bounded Mac/physical-iPhone Shortcuts check is complete: default denial, explicit sharing, successful authorized snapshot after phone background/runtime stop/reconnect, then user-confirmed offline withdrawal followed by verified denial. This supersedes earlier pending/unproven live-success statements. See [the full sequence and evidence limits](Shared-Status-Shortcuts-2026-11-08.md#november-9--bounded-permission-lifetime-live-check-complete). Restart/crash recovery, save failures and identity changes retain their separate fixture-only evidence; no broader live certification or new feature scope is implied. R1 remains accepted.
