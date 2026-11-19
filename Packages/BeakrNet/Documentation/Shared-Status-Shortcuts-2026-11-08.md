# Foreground Shared Status Shortcuts action

November 8, 2026. **Permission-lifetime implementation and bounded Mac/iPhone Shortcuts live check completed November 9. See the latest evidence below: restart and network-switch retention are user-confirmed; interruption/write-failure recovery remains fixture-scoped. The closeout withdrawal/submission finding PL-1 is corrected and fixture-verified; the user accepted this bounded increment November 9 under the final commitment contract and evidence limits below.** User authorized implementation after a read-only assessment. R1 remains accepted. This is a bounded caller for the existing service, not general Siri/AI delegation.

## November 9: persistent permission lifetime implemented

User authorized the bounded implementation after the read-only review and subsequent compatibility discussion. The parked November 8 section below remains historical. Persistent intent is now implemented; it is no longer only a proposal. R1 remains accepted, and no streaming, monitoring or remote-configuration service was added.

### Ownership and scope

`SharedStatusPermissions.swift` supplies an app-owned coordinator and one actor-isolated writer per profile. It stores a versioned `shared-status-permissions.json` beneath the existing `Profiles/<profile>/<network>/` runtime root, separately from Context history and presentation metadata. The document binds profile/network/local-node IDs; each entry binds remote-node ID and the fixed `beakr.status/read/v1` operation. It pins authority public key, environment, both membership credential IDs and both node public keys. Public keys are stored for exact equality, not private credentials. Names, session IDs and runtime binding IDs are not saved permission keys. Existing ephemeral choices are not migrated; an absent grant is off.

App composition shares the coordinator between bootstrap and LAN runtime management. `ProfileMembershipDirectory.serviceAuthorizationSnapshot()` returns a coherent observation of verified records, current endpoint eligibility and invalidated credential IDs. Historical records alone are not live authorization. Signed removal/replacement IDs are remembered during the directory lifetime, so removal followed by reappearance between observations does not preserve a prior grant. No wire format, transport authentication or membership schema changed.

`SharedStatusRuntime` still owns transient bindings, request clients and responders. It reconciles saved intent against verified state at startup, maintenance and use, including before response submission. Ordinary disconnect cancels pending work and destroys capabilities without erasing intent. Reconnect obtains a fresh capability only after current route/session, membership and permission checks. Temporary expiry/unavailability blocks access without erasing intent. Credential/key or authority changes invalidate old grants; certificate renewal retaining the same credential/key does not. Explicit revocation and signed removal invalidate saved grants, including offline peers. Existing profile-removal paths retire cached permission handles before scoped cleanup. No live removal or revocation was performed.

### Persistence, withdrawal and recovery

The permission actor serializes bounded synchronous file effects, uses expected revisions for commands, and atomically replaces the document. Enablement is published only after saving succeeds. Withdrawal first blocks in memory and changes the revision, then saves off; suspended disclosures cannot pass the final permission revision check. Responses atomically committed for submission before withdrawal are in flight and may still arrive; withdrawal prevents new commitments. Bytes already submitted cannot be retracted. A persistence error blocks sharing for that profile; an explicit successful Save Sharing Off operation can clear the failure. Corrupt, mismatched or unsupported documents block the service and are not silently overwritten.

Before permission use or editing is accepted, the store must durably arm its session-open guard. Failed guard creation rejects the operation and blocks sharing; it does not claim that an off choice was durably saved. The guard remains armed after a failed mutation. Background/termination checkpoints mark it clean only after runtime stop and successful permission writes. Subsequent use/commands re-arm it. Reopening an unclean document requires explicit per-peer confirmation or clearing of saved choices. Thus ordinary reconnect and clean restart preserve intent; interrupted sessions can require reconfirmation. This is application interruption/write-failure recovery using existing atomic-file conventions, not a claim of filesystem rollback resistance or cross-store transactions.

The small permission state machine is represented by serialized transitions among off/allowed, confirmation required, persistence failure and retired state, with runtime availability kept separate. Grant revisions invalidate stale asynchronous results; a late UI command cannot restore a withdrawn grant. One writer and observed immutable snapshots keep windows consistent.

### UI and caller boundaries

The accepted details/menu/sheet presentation is retained. The toggle shows saved intent independently of the current connection. Offline or inactive-profile peers can be withdrawn without starting networking. Enabling requires the selected local network runtime and currently verified, eligible membership for both endpoints; the remote peer may be offline. The command validates membership before saving and reports an error if it cannot verify it. Merely displaying an enabled control does not establish authorization. Recovery and save failures have explicit messages and a Save Sharing Off action. Permission observation is independent of runtime observation and scoped to profile/peer identity. Requests remain tied to live bindings. Shortcuts remains request-only; the five-second readiness window and ten-second reply deadline are unchanged. Saved picker membership remains display-only.

### Validation and limitations

Authorized baseline identity was verified from device.plist: Beakr-R1-Contract-Baseline-20261026, E40CDB24-C697-4F57-8F87-CBFD9DFADDD5, iOS 27.0. New fixtures use temporary files and real signed membership verification with injected transport routes; they do not certify new TLS, system App Intents execution or live UI behavior.

- 15 cases passed at 15:35:33 EST: reconnect, clean/interrupted restart, offline withdrawal, failed enable/withdrawal, stale commands, temporary trust loss, peer revocation, unchanged-credential republication, six storage/isolation variants and withdrawal during sampling.
- 9 cases passed at 15:37:08: four additional identity/removal cases, persistent denial → reconnect/allowed response → withdrawal/denial, pending cancellation on disconnect, two-observer consistency/retired handles, failed guard creation, and the existing status/chat separation regression. The latter was rerun because its runtime adapter changed.
- 2 cases passed at 15:38:08: authority replacement and signed removal/reappearance between observations.

These establish **25 distinct new cases plus one existing regression**, not a full suite. Xcode initially reported only one of five identity-invalidation arguments, so those scenarios were split into named tests and the four missing cases run explicitly. The first test invocation supplied no retained usable result and is not counted. Certificate-renewal coverage establishes unchanged membership identity across signed republication, not an actual certificate-issuance exchange. Cross-window evidence is observer/coordinator coverage, not automated UI testing.

BuildProject passed with tests for baseline iOS at 15:32:13, 15:34:27, 15:36:50 and 15:37:46; Mac passed 15:38:23; physical iPhone passed 15:38:57. The initial 15:31:50 build caught a missing BeakrNetAuthority import, corrected before successful builds/tests. Artifacts: `ActionArtifacts/B5657014-DCEC-4DE2-B845-3E33F0DE8B38`, RunSomeTests summaries `B67AC35A-0669-4E3B-B640-85CBC3BDBFD9.txt`, `7EF429CA-7860-485F-90CD-E66ED2D62E55.txt`, `30ACDF60-B973-4567-B82D-04AE040746DF.txt`, and dated BuildProject logs.

At the initial implementation checkpoint, no Mac/physical-device launch, UI interaction, console interpretation, live revocation, re-enrollment or protected-profile operation had occurred. UI presentation and authorized live Shortcuts success were then unverified; later evidence below supersedes that status. Xcode is left on 360-iPhone-Dev for a separately scoped user-operated phase. Reconfirm Conditioner, selected network and authority hosting before that phase; verify platform/session/PID and loaded build for both devices before using logs.

New-file registration left SharedStatusPermissions.swift AM and changed the index fingerprint from `358f069b14417374fd315775b6edacd6000a6d8b5103bd95774a842b7c664041` to `d4b19470057c3eaa9adcdb788d3d189355dd97f6e3d7eca94f3d1221f5504f53`. No stage/reset/commit command was issued; the index was preserved and the user informed.

## Current behavior

`RequestDeviceStatusIntent` exposes **Request Device Status** with one Device parameter and a text/dialog result. It declares foreground execution, main-app execution and authentication on the executing device. It does not add an AppShortcuts provider, automatic Siri phrase, donation, Spotlight indexing, interactive snippet or language model. A person can compose a shortcut using the action; system discovery and invocation were subsequently demonstrated in the bounded user-operated checks recorded below.

`StatusDeviceEntity` identifies a target using canonical network UUID/node UUID, independent of friendly names, local profile IDs and transient runtime/session bindings. Device and network names are presentation only. `StatusDeviceQuery` supports identifier lookup, suggestions and name/network search from the selected network's current member projection. Multiple name matches remain multiple candidates; the app does not select the first by name. Queries read existing state without creating a runtime binding, sending a request, probing permissions or switching networks. A cold/unloaded model may produce no suggestions; this increment does not add a separate persisted directory or promise cold-start query restoration.

`StatusIntentAdapter` is registered through AppDependencyManager in the existing BeakrApplicationModel construction. It uses that model's NodeBootstrapModel and runtime; no second networking stack or extension is created. Its injectable boundary offers only selection lookup, runtime availability and request. It has no sharing-change, membership or network-switch operation.

Execution validates the saved network/node target against current selection and excludes the local device. It resolves the selected runtime, obtains its current binding UUID and invokes SharedStatusRuntime.request. Selection is rechecked after asynchronous resolution/availability and after the reply; a changed or removed target suppresses the result. Reply network/local/remote identity must match the request. Existing authenticated transport, membership eligibility, binding checks, remote default-off permission, one pending request per binding, ten-second timeout and runtime invalidation remain authoritative.

The local outgoing-sharing toggle is not checked as permission to request: it controls the opposite direction. Remote sharing remains required. This authorizes a trusted local application caller using peer-level permission, not an independently authenticated Siri Actor. Local device authentication is an additional OS execution restriction, not a remote permission grant.

Success returns the resolved device/network names plus version, runtime state, connected-device count and sample time as text and dialog. The result is a snapshot; Siri/Shortcuts may display, speak or pass this intentionally returned text to subsequent user-configured actions. It contains no message history, addresses or credentials. No new persisted result store is added. Typed errors distinguish invalid target, not ready, selection changed, denial, busy, timeout, cancellation, unavailable and invalid response. System intent cancellation and Swift task cancellation cancel the child request task; existing service cancellation does not retract bytes or force remote sampling to stop.

## Lifecycle limits

Beakr's background transition stops its networking runtime. This action foregrounds Beakr and now allows a five-second monotonic readiness window for the selected runtime and peer binding. It checks existing state at 100 ms intervals without starting networking, switching networks or retransmitting a status request. Cancellation and selection changes abort the wait. If no binding becomes ready within the window, the action returns not ready. The existing ten-second service reply timeout starts after readiness, so the nominal combined wait can approach fifteen seconds. An initially unloaded selection still returns not ready immediately; cold-start restoration remains outside this change. Remote devices must also have their runtime available and sharing enabled for the current binding. Cross-device shortcut identity can resolve only where the executing app has the matching selected membership and member projection; synchronized availability is not promised.

## Changed components

| Component | Change |
| --- | --- |
| Apps/Beakr/SharedStatusIntent.swift | Entity/query, localized intent errors, narrow adapter, foreground action and cancellation bridge |
| Apps/Beakr/BeakrApp.swift | Register adapter from the existing application composition root |
| Apps/BeakrTests/SharedStatusIntentTests.swift | Deterministic adapter fixtures; no live networking |

Existing service, dispatcher, runtime permission policy and UI code were not modified for this phase. Terminology remains provisional. Earlier Shared Status UI review is complete within user acceptance: the user confirmed the current-device menu action is unavailable as intended; broader wording improvements remain deferred.

## Validation and evidence

Xcode BuildProject passed on the authorized baseline simulator at 21:13:01 and with tests at 21:14:09 (12.041s), then on My Mac at 21:14:47 (10.331s). Earlier builds caught an initially unregistered source file, missing BeakrNetData import, dependency autoclosure capture, and default-main-actor isolation on the injected runtime protocol. These were corrected before final validation. The protocol is explicitly nonisolated so production and fixture actors conform consistently.

Eight focused Swift Testing cases passed at 21:14:22:

| Test | Evidence |
| --- | --- |
| discoveryDoesNotResolveRuntime | Lookup reads no runtime; entity identity survives name changes |
| rejectsInvalidTargetsBeforeRuntime | Malformed, wrong-network, local and missing peer targets rejected before resolution |
| unreadyDoesNotRequest | Missing selection/runtime returns not ready without sending |
| readsWithLocalSharingOff | Valid request passes current binding and returns attributed snapshot despite local sharing off |
| preservesServiceFailures | Remote denial, busy, timeout, invalidation and unavailable remain distinct errors |
| selectionChangeBeforeSend | Changed selection after resolver await prevents request |
| selectionChangeSuppressesResult | Changed selection while awaiting reply suppresses result |
| cancellationReachesRequest | Cancelling adapter task interrupts pending fixture request |

These are in-process adapter tests with an injected runtime. They do not execute the App Intents framework, certify system unlock behavior, prove parameter disambiguation UI, or exercise the actual Siri cancellation callback. Existing service cases were not rerun without a change. The compiled iOS Metadata.appintents/extract.actionsdata contains RequestDeviceStatusIntent and StatusDeviceEntity; metadata presence is not live discovery evidence.

Baseline identity verified from device.plist: Beakr-R1-Contract-Baseline-20261026, E40CDB24-C697-4F57-8F87-CBFD9DFADDD5, iOS 27.0. Result summary: ActionArtifacts/4217D839-B9D4-4398-A0DD-4C3422C07B03/RunSomeTests/E5A948AF-B63D-462E-85D8-B3A319685464.txt. No physical iPhone/Mac app launch, live console interpretation, live request or other simulator interaction in this phase. Xcode remains My Mac. NLC/hosting need fresh confirmation for a future live check.

No stage/reset/commit commands were issued. Xcode registration work left SharedStatusIntent.swift AM and SharedStatusIntentTests.swift A; exact staging mechanism was not established. Index SHA256 changed from the previously recorded 99377a320aa3f3a114b6034d53b6719f2287f0e3f7d0c51c9bd691ad847793ac to 358f069b14417374fd315775b6edacd6000a6d8b5103bd95774a842b7c664041. Index preserved and user informed.

## Next separately scoped check

User-operated Shortcuts discovery/execution on one physical iPhone against the existing Mac status responder: verify current binaries and console identities, reconfirm NLC/hosting, verify Device selection and foreground/not-ready behavior, then denial/explicit sharing/one snapshot/withdrawal. Do not infer authorization from completion of this implementation. Background operation, new remote permissions, general delegation, free-form AI, persistent result indexing and multi-network participation remain excluded.

## Framework references consulted

Apple-provided local App Intents specialist guidance and the iOS 26/27 execution-mode reference were read before implementation. Current Apple documentation was checked with Xcode DocumentationSearch for [execution targets](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets) and [local-device authentication](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/requireslocaldeviceauthentication). Entity/query, dependency, error and execution-model guidance informed the composition and identity boundaries above.

## Live discovery and picker follow-up — November 8, 21:42 EST

User-operated physical iPhone Shortcuts editor found and added Request Device Status (screenshot 21:36:57). Earlier failed search was on Describe a Shortcut, not the action editor. Device picker then displayed No options available (21:38:00); no status execution result claimed. Mac verified session 7c80f76e80/PID37743, OSLog session B1F87476-3740-4857-BFCF-93F737FF3C4C, loaded image 16DF9FC4-C6F0-3877-8185-D25237892B90 matched build. User selected iPhone PID9165 correctly, but console/debugger tools still returned Mac. Screenshot 21:40:39 shows iPhone background/inactive lifecycle and zero-peer update; that does not independently establish its query/member-array state. Root cause is not yet proven.

Bounded picker correction: when the live member list is empty, reuse the selected profile's existing SavedNetworkMembership projection (including stale historical membership for display only; unavailable produces no entries). No new persistence, network probe, switch or grant. Live request binding and authorization checks are unchanged. An unloaded selection now throws the localized not-ready error instead of silently returning an empty list. Added StatusIntent OSLog query diagnostics with platform, PID, selection-present and result count; no device names/payloads. This does not promise a cold-start membership loader or prove the reported live picker issue resolved.

Baseline build with tests passed 21:42:12. Three focused cases passed 21:42:21: changed discovery path, new saved-member fallback/precedence/unavailable/stale cases, and unloaded selection error. Two new tests; earlier eight results remain separately scoped. Summary 1EB71455-3E6E-4911-AFC1-2044ADA6C2E6.txt under the existing ActionArtifacts RunSomeTests directory. Physical iPhone BuildProject passed 21:42:32, 6.988 seconds. Xcode left 360-iPhone-Dev for user launch and picker recheck; no agent physical interaction or status request. Fresh NLC/hosting checklist was asked but has not received an explicit answer for this live phase; do not begin requests until confirmed.

## Foreground readiness correction — November 8, 21:50 EST

User screenshot 21:44:25 confirms picker now includes MacMini-Ice-9/XYZ and three saved placeholder-name peers. User explicitly confirmed NLC off on both, XYZ selected, Mac XYZ authority Running, E8 Stopped and Mac sharing with phone off before execution. Screenshots 21:47:26/21:47:38 show Beakr launched, XYZ later displayed two online devices, but the action returned localized not-ready. This confirms foreground launch and error presentation, not a successful remote request or authorization denial. Tools continued returning verified Mac PID37743, not the new phone session; no iPhone console/loaded-image verification claimed. Physical on-disk dylib UUID before this correction was ABAE7D08-C4A8-398E-850B-1E7EB6B1A6D1.

User authorized bounded readiness wait. Implementation observes existing runtime/peer availability for up to five seconds using ContinuousClock and cancellable sleeps, revalidates selection after each await, then sends once through the existing service. No new networking lifecycle, permission change or request retry. Local status permission remains independent of outgoing requests.

Baseline build with tests passed21:49:54; seven focused tests passed21:50:07: four new readiness cases (runtime plus peer become ready then one send; deadline without send; cancellation during wait without send; selection changes during wait without send) and three existing cases rerun because their request path changed (unready, local-sharing-off success, service errors). Summary2032CAA8-0646-47AD-9EED-02A94F43A80D.txt under existing ActionArtifacts/RunSomeTests. Mac BuildProject passed21:50:22 (10.62s); physical iPhone passed21:50:28 (4.176s). Xcode targets360-iPhone-Dev for user launch/recheck. No agent device interaction or accepted R1 rerun. Live verification of the correction remains pending.

## Parked: connection-scoped permission conflicts with Shortcuts

User requested this case be set aside until their return tomorrow. No further implementation or testing was performed after that instruction. This section supersedes earlier pending-discovery/readiness status statements.

The 21:54:00 screenshot shows Shortcuts reporting “This device hasn’t allowed you to read its status.” Verified Mac session7c80f76e80/PID37743 logged authorization denied at21:53:18.497847, correlation778C5F2F-133C-4997-8DEA-5F39D21EAC60, status runtime828F3542-C7FD-470C-B5D9-268DE56D24BB. Sender path, session and image match the previously verified Mac. Thus the corrected foreground readiness path reached the responder and denial surfaced in Shortcuts. No phone log timing or allowed Shortcuts response is claimed.

User observed that switching to Shortcuts immediately makes iPhone-Dev offline on Mac; foregrounding Beakr restores presence but not the enabled sharing setting. This matches current ownership: background stops the phone runtime, peer connection loss discards the Mac's service binding, and a replacement binding defaults off. The readiness fix waits for reconnection; it intentionally does not restore permission. Ordinary Shortcuts use therefore conflicts with connection-scoped sharing. The proposed Siri timing workaround was not validated and is not the recommended next step. Earlier successful in-app status exchange remains valid within its original scope.

### Proposed bounded permission-lifetime design — not implemented

Purpose: preserve a deliberate local permission choice across ordinary backgrounding/reconnection while retaining live membership/authentication checks and immediate withdrawal.

Separate saved user intent from runtime capability. Persist only a grant for the fixed status-read operation, scoped to the local membership identity (profile/network/local node) and authenticated remote node. Names, IP addresses, transport/session IDs and runtime binding UUIDs are not persistent grant keys. No wildcard grant and no migration of existing ephemeral enabled state: absence defaults off. There is no backwards-compatibility requirement.

Ordinary disconnect/runtime stop cancels pending work and invalidates the transient capability, while retaining the saved choice. A replacement capability may use that choice only after current signed membership eligibility and authenticated peer/session checks succeed. A saved choice is not itself proof of authority. Inactive networks do not execute requests. Returning to an existing membership may restore its choice only after the same checks.

The permission store should be owned by app composition, with the runtime consuming a narrow read/update interface and the UI editing that source of truth. Audit existing profile-scoped persistence before adding any store. SharedStatusRuntime retains responsibility for per-connection clients, responders, binding UUIDs and permission revision checks; SharedStatusSection reflects saved choice separately from current availability. StatusIntentAdapter remains request-only. No new general framework is required.

Withdrawal must disable current responders immediately and invalidate any suspended disclosure, then persist off without allowing a failed save or concurrent reconnect to restore permission silently. Failed enabling must not grant transient access and must surface an error. Define atomic-write/error behavior and cross-window synchronization before implementation. Previously returned snapshots/bytes cannot be retracted.

Explicit revocation, forgotten/replaced local membership or a different remote identity must not inherit a grant. Distinguish temporary trust unavailability from explicit revocation: unavailable trust blocks access; explicit revocation should invalidate the saved grant. Credential rotation/re-enrollment under an unchanged node ID needs an explicit policy decision before coding—do not silently treat every same-node credential as equivalent or every renewal as a new identity. Determine that policy from existing credential/lifecycle contracts, with fixtures only; do not perform live revocations or re-enrollment.

Affected components: existing app composition and profile persistence, SharedStatusRuntime, SharedStatusSection, focused permission fixtures; update the service contract and Shortcuts evidence. No changes to transport authentication, network startup/background policy, authority roles or membership schemas unless the bounded design demonstrates necessity.

Acceptance for a later authorized implementation:

- Default off, exact local-membership/remote-node/operation isolation, no inheritance by names or replacement identities.
- Deliberate enable survives ordinary reconnect and app restart; no status is disclosed until fresh live authorization passes.
- Disable remains off across reconnect/restart, including concurrent sampling and persistence failures.
- Explicit revocation/replacement fails closed with a defined re-grant policy; exercise using fixtures, not live memberships.
- UI distinguishes saved permission from online/available state; offline peers can have their saved choice withdrawn without needing an active transport.
- Existing Shortcuts action remains unable to grant access or switch networks. Only after fixtures pass, a separately scoped user-operated denial → enable → background/reconnect → allowed reply → disable → denial check establishes the workflow.

Exclusions: general User/Actor delegation, background networking, mandatory audit infrastructure, Siri/AI interpretation, automatic sharing, multi-network participation and broad terminology review. This document is a recommendation, not implementation approval. Resume by reviewing the permission-lifetime and credential policy, not by repeating accepted R1 checks or asking the user to race the current toggle.

Final live hosting/NLC state was not rechecked at parking time. Last confirmation preceded the denial test; treat it as historical on resumption. No user request to stop apps or change hosting was issued. No reminders/scheduled task created. Workspace and staging preserved; no reset/stage/commit.

## November 9 live verification — in progress

Fresh user confirmation: Conditioner OFF on both devices, XYZ selected on both, Mac XYZ authority Running and E8 Stopped. User launched both new builds. Verified physical iPhone launch7c80f0a700/PID10218/loaded image96FFF225-59B7-3818-B21A-6E7A4285B593 and Mac launch7c8093bc00/PID44546/loaded imageB2FB9155-E5D4-3635-BE00-23CF6140C65A. User reports Shortcuts permission denial. Mac logged three denied requests; latest15:49:30 correlationCBE82E42-E261-4904-B74B-8999A9A01808 matches iPhone remote-unauthorized completion6.809834ms. This is sharing-off denial evidence, not an authorized result or performance benchmark. Enable → background/reconnect → allowed reply and offline withdrawal remain pending. All app interactions user-operated; no live revocation/re-enrollment or protected-device action.


### November 9 — authorized Shortcuts response after background/reconnect verified

User screenshot supplied15:51:42 shows Shortcuts result: MacMini-Ice-9 on XYZ, Beakr1.0, runtime Running, one connected device, sampled15:50:53. Explicitly queried phone launch7c80f0a700/PID10218 and Mac7c8093bc00/PID44546; sender paths, OSLog sessions and loaded image UUIDs still match their verified November9 builds. Phone logs background/runtime stop15:50:47, foreground15:50:51, then request61F0604D-463F-40FE-B733-7EC833386623 at15:50:53.621021 and successful completion8.237917ms later. Mac logs matching authorization allowed15:50:53.628927. Phone status runtime is newly D74699D8-0302-4A58-B4B9-5E41C3BDF039; Mac runtime remains824B4CA1-9996-41B5-864A-0214813182E0.

This establishes one authorized live Shortcuts snapshot after the phone background-stop/foreground-reconnect sequence, superseding earlier statements that allowed Shortcuts success is unproven. It is not restart/crash recovery evidence or a latency benchmark. Mac toggle retention was not separately visually confirmed. Next bounded step: with phone Beakr backgrounded and shown offline on Mac, withdraw Mac sharing for iPhone-Dev, then run the same shortcut and verify denial. Offline withdrawal remains pending; do not mark the whole live phase complete. No source change, build/test, agent device interaction, staging/reset/commit or protected-history operation.


### November 9 — post-withdrawal Shortcuts denial verified; offline timing confirmation pending

User screenshot15:53:37 shows Shortcuts notification “This device hasn’t allowed you to read its status.” Verified current Mac/iPhone session, PID, platform sender paths and loaded build UUIDs remain unchanged. Mac authorization denied15:52:59.947462 and iPhone remote-unauthorized completion9.497167ms match correlation288C2499-121C-4432-9581-FF5868496B3F. Phone status runtime71D3EAE6-790B-4608-9716-BD32880F74BB is another fresh runtime; Mac status runtime unchanged. Default denial → authorized snapshot after background/reconnect → subsequent denial is established. The screenshot does not show the Mac permission control or prove phone-offline state at the moment of withdrawal. Ask only for that user confirmation; do not repeat the passed requests. No new implementation, builds/tests, agent device actions or index changes.


### November 9 — bounded permission-lifetime live check complete

User explicitly confirmed “yes” that iPhone-Dev was shown offline on Mac when sharing was successfully turned off. Offline withdrawal is therefore user-confirmed, followed by the independently correlated denial at15:52:59 (288C2499-121C-4432-9581-FF5868496B3F). The bounded user-operated live sequence is complete: sharing-off denial → explicit sharing → phone background/runtime stop and foreground/reconnect → authorized Shortcuts snapshot → offline withdrawal → reconnect/denial. The successful response at15:50:53 is correlated by61F0604D-463F-40FE-B733-7EC833386623 and the supplied screenshot. Mac PID44546 and physical-iPhone PID10218 used the verified November9 builds throughout these observations.

Scoped PASS. Offline control state is user testimony; screenshots/logs establish the displayed results and matching service outcomes. No live process-restart/crash recovery, storage-failure injection, credential rotation, revocation, re-enrollment, broad UI/accessibility audit or performance benchmark is claimed. Those fixture scopes remain separate. R1 acceptance is unchanged. Sharing was withdrawn for this Mac-to-phone status-read permission; no new grant or cleanup action is requested. No further testing or feature implementation is implied. No source/build/test, agent device interaction, staging/reset/commit or protected-history operation in this recording step.


### November 9 — offline enablement correction (16:07 EST)

User rejected locking saved permission configuration merely because the target is offline. The earlier connected-peer requirement is superseded. SharedStatusSection now observes the selected runtime even for an offline peer, and the toggle no longer depends on a live binding. SharedStatusRuntime.setSavedSharing no longer requires a transport route; it still checks scope, verified membership, both eligible credentials and invalidated IDs. Offline withdrawal remains independent of runtime availability. Enabling while the local profile/runtime is inactive remains unavailable with an explanation; this change does not start or switch networking. Request availability and final disclosure authorization are unchanged.

BuildProject passed for the verified baseline simulator with tests16:06:26, Mac16:06:58 and physical iPhone16:07:03. Six focused cases passed16:06:37: persistentExchange now enables while offline, checks no request binding, then receives a snapshot after reconnect and denial after withdrawal; two new cases reject expired/missing verified membership; offlineWithdrawal, staleCommands and suspendedDisclosure remain passing. Summary DBCBFA08-24D8-4D2C-A813-523AA8EE10A2.txt in the existing ActionArtifacts RunSomeTests directory. No new live or automated UI result is claimed.

On-disk build UUIDs: Mac43D880E6-1DE9-30FB-ADEA-8CE5976500AC; iPhone7CC2A30F-6DC7-3350-B609-E2987188C608. These have not been verified as loaded. Xcode left My Mac. User reports iPhone is green on the earlier running build. Next bounded phase: user launch corrected Mac build, verify its session/PID/platform/image, then test offline editing on the Mac after fresh Conditioner/XYZ/authority-hosting confirmations. Clean-restart persistence testing remains paused. Index hash unchanged d4b19470057c3eaa9adcdb788d3d189355dd97f6e3d7eca94f3d1221f5504f53; no staging/reset/commit or protected-history operations.


### November 9 — user-confirmed restart and network-switch retention

User reports: “the shortcut works and the Share Status button is preserved over app restard and also switching back and forth from XYZ to E8-Test”. Record successful Shortcut execution and preserved sharing selection across app restart and XYZ ↔ E8-Test switching as user-confirmed observations. This supersedes the earlier paused/pending restart status for the reported behavior. The report does not establish that XYZ permission is granted in E8-Test; grants remain profile-scoped.

No new console session/PID/platform/loaded-image verification or request correlation was collected for these observations. Do not attribute them to a specific build UUID or claim crash recovery, offline enablement UI verification, or cross-profile authorization isolation from this report. Offline enablement remains fixture-verified with live UI confirmation outstanding. Earlier independently correlated Shortcuts evidence remains valid within its recorded scope. No repeat of the reported successful restart/switch checks is requested. No new code, builds/tests, device interactions or staging/reset/commit; R1 acceptance and protected histories remain unchanged.


### November 9 — offline-control preflight confirmed; Mac session verification pending

User freshly confirmed Conditioner off on both, XYZ selected on both, Mac XYZ authority Running / E8 Stopped. Read-only Xcode console query returned physical iOS session7c80f0a700/PID10218, sender image96FFF225-59B7-3818-B21A-6E7A4285B593, OSLog session05495AA5-83E5-4AE5-8F70-301F9ABE4567, latest returned logs16:13:51. Debugger process status also identified PID10218. This is the earlier phone build, not evidence of the corrected Mac build. Explicit query for previous Mac session7c8093bc00 failed (session not found); shell process listing was unavailable. No Mac loaded-build claim or offline-control result. Next: user select current Mac Beakr debug session, or user launch My Mac if no session exists, then verify platform/PID/image before changing the offline sharing control. No app interactions, builds/tests or source changes in this preflight.


### November 9 — corrected Mac build verified through user debug console

User screenshot shows selected Mac Beakr PID48012 and macOS lifecycle logs in its console. User supplied LLDB `image list -u -f Beakr.debug.dylib` output: UUID43D880E6-1DE9-30FB-ADEA-8CE5976500AC at /Users/ice-9/Library/Developer/Xcode/DerivedData/Beakr-bldiwivmpglpeobyoifeyjlugaej/Build/Products/Debug/Beakr.app/Contents/MacOS/Beakr.debug.dylib. This matches the corrected Mac build. Evidence comes from the user-selected Mac console, not the tools that continued returning iPhone PID10218. Environment was freshly confirmed in the preceding preflight. User was instructed to resume after the brief debugger pause; resumption is not yet independently confirmed. Next bounded user-operated check: resume Mac, background phone Beakr, wait for iPhone-Dev to appear offline on Mac, then change saved sharing off → on while it remains offline. No offline-toggle success or request outcome claimed yet; no new code/build/test or agent device interaction.


### November 9 — offline enablement UI confirmed by user

Following verification of corrected Mac PID48012 / image43D880E6-1DE9-30FB-ADEA-8CE5976500AC, user reported the iPhone-Dev Shared Status selection on Mac was Off. In response to the instruction to enable it while iPhone-Dev remained offline with Beakr backgrounded, user confirmed “stays on”. Record offline Off → On retention as user-confirmed UI evidence. This completes the outstanding narrow offline-enable control check; no new request outcome or disclosure while offline is claimed. Next bounded step is user-operated execution of the existing iPhone Shortcut to check access after reconnect. Earlier restart/network-switch and correlated service evidence retain their separate scopes. No code, builds/tests, automated device interaction, staging/reset/commit or protected-history changes.


### November 9 — offline enablement followed by successful Shortcut: user-confirmed pass

User confirms: “Yes it works from the iPhone and Mac/iPhone status remains On”, after being instructed to run the existing Request Device Status Shortcut targeting the Mac following offline Off → On enablement. The bounded sequence is complete as user-confirmed evidence: phone offline → save sharing On on corrected Mac → run iPhone Shortcut → successful status result, with the Mac control for iPhone sharing remaining On. This does not assert reciprocal sharing permission on both devices.

Mac build was verified through the user-selected debug console: PID48012, image43D880E6-1DE9-30FB-ADEA-8CE5976500AC. This final request has no independently collected console correlation or new phone loaded-build verification; distinguish it from the earlier correlated request evidence. Offline-control UI and subsequent successful request are now user-confirmed; no repeat is needed. Sharing remains On by the user's deliberate choice. Earlier app-restart and XYZ ↔ E8-Test retention remain separately user-confirmed. No crash-recovery, credential-change or performance evidence is added. R1 remains accepted. No further live testing or implementation is initiated; no code, builds/tests, automated app interaction, staging/reset/commit or protected-history changes in this recording step.


## November 9 — read-only permission-lifetime closeout review

Recommendation: the intended user workflow is demonstrated, but hold final acceptance of this increment pending one bounded concurrency investigation. R1 remains accepted. No source changes, builds or live tests were performed for this review.

Implemented boundaries checked: profile/network/local-node/remote-node/fixed-operation scope; authority and credential/key pinning; a single permission writer; atomic replacement and explicit save-failure state; interrupted-session confirmation; retirement hooks; disconnect invalidation without deleting intent; separate saved-permission and request availability; offline enable through verified membership; offline withdrawal independent of transport. Streaming, monitoring, remote configuration, query proofs and general Actor delegation remain proposals, not implemented capabilities.

Evidence reconciliation:
- Initial fixture evidence: 25 distinct new cases plus one existing regression. Offline correction added two new cases and reran four relevant cases (six passing); these are not six additional distinct cases.
- Correlated live evidence: default denial, authorized Shortcuts snapshot after background/reconnect, and denial after withdrawal. Offline withdrawal timing is user-confirmed.
- Further user-confirmed evidence: app-restart retention, XYZ ↔ E8-Test selection retention, offline Off → On on verified corrected Mac PID48012/image43D880E6-1DE9-30FB-ADEA-8CE5976500AC, then successful iPhone Shortcut with the control remaining On. No new correlation or phone-build verification is claimed for that final request. Profile-switch retention does not itself demonstrate cross-profile authorization isolation.
- Interruption, failed persistence, credential/authority changes and stale-command protections remain fixture-scoped. No crash, live revocation/re-enrollment, performance or broad accessibility claim is added.

Open finding PL-1 — final permission check and transport handoff are not serialized with withdrawal:
SharedStatusRuntime.send obtains a revision through awaited permissionRevision/permissions.authorization, then asynchronously calls submit. The store can process withdrawal after returning that revision but before submission executes; the local Slot value captured in send remains unchanged. The production submit closure hops to ProfileConnectionRegistry.submit, which checks the route ID and invokes driver.deliver, but does not carry/check the saved-permission revision. Thus code inspection identifies a possible previously sampled response submitted after withdrawal has completed. This is a concurrency concern, not an observed live disclosure. The existing suspendedDisclosure test withdraws while sample() is suspended, before the final permission check; it does not cover the later handoff interval.

Before acceptance, define the exact point at which a response is committed and serialize permission withdrawal against that point. Add a deterministic fixture that pauses after the last permission read and before submission, completes withdrawal, then resumes; a response not yet committed must be suppressed. The design must also explicitly classify a response already committed before withdrawal as in flight; merely adding another awaited check leaves the same ordering problem. Recommend this as the next bounded investigation/fix, with no broad networking refactor or new live testing. No implementation is authorized by this review alone.

Earlier documentation describing immediate withdrawal and the final revision check should be read with PL-1 until resolved. Successful workflow evidence remains valid and should not be repeated. Saved sharing remains On by the user's choice. Index/workspace and protected profiles/history are preserved.


## November 9 — PL-1 corrected and fixture-verified (16:30 EST)

User authorized the bounded investigation/fix. The new withdrawalBeforeCommit fixture paused after the final permission read and before submission, completed withdrawal, then resumed. Before the correction it failed as predicted: wire.writes was nonzero (16:28:17; summary5EFB4EDA-5187-4748-953E-1A4EC2802F0E.txt). This reproduced the ordering defect in an injected transport fixture, not on live devices.

SharedStatusPermissionStore.commitDisclosure now validates the expected revision, grant, recovery/failure/retirement state and cancellation, arms the recovery guard if necessary, and creates one submission Task in a single non-suspending actor turn. This is the explicit response commitment point. Withdrawal and commitment share the same serialized owner: withdrawal first suppresses the prepared response; commitment first makes that response in flight. A committed response may be sent or arrive after the toggle becomes Off. Commitment is not a transport acknowledgement or delivery guarantee. Withdrawal does not wait on slow networking. The runtime awaits the task, propagates cancellation, and rechecks runtime/binding/route before transport submission; existing transport authentication, membership and delivery checks remain. No persistent queue, automatic retry, new background execution mode or general delegation framework was added. The optional pre-commit scheduling seam is nil in production.

This resolves PL-1 at the defined commitment boundary, rather than claiming that another asynchronous permission read makes check-and-send atomic. Earlier wording limiting the exception solely to bytes already submitted is superseded: responses committed before withdrawal are also in flight. Responses not yet committed must not pass a completed withdrawal.

Validation: baseline simulator identity reverified as E40CDB24-C697-4F57-8F87-CBFD9DFADDD5 / Beakr-R1-Contract-Baseline-20261026 / iOS27.0. BuildProject with tests passed16:28:10 for reproduction,16:28:52 after the implementation, and16:29:24 for final test sources. An intermediate16:29:13 build found a misplaced test-fixture closure; corrected before the final build/run. Eight tests passed16:29:25: withdrawalBeforeCommit, withdrawalAfterCommit (withdrawal completes while committed submission is gated), retirementBeforeCommit, suspendedDisclosure, persistentExchange, failedPersistence, staleCommands, pendingDisconnect. Three new tests and five relevant regressions; not a full-suite rerun. SummaryA06C21D6-0F95-4521-9F85-D609E31699F0.txt under ActionArtifacts/B5657014-DCEC-4DE2-B845-3E33F0DE8B38/RunSomeTests.

Mac BuildProject passed16:29:47; physical-iPhone build passed16:29:55. On-disk image UUIDs: Mac3E597813-C78E-3080-AADC-D8C1D9D0B872, iPhoneA6C83E40-2153-305D-B266-BD3204D045EC. Neither is claimed loaded or live-verified. Xcode left My Mac; no agent Mac/phone interaction, live tests, revocation or profile changes. Previous live workflow evidence belongs to its recorded builds. Source diff whitespace check passes; index hash remains d4b19470057c3eaa9adcdb788d3d189355dd97f6e3d7eca94f3d1221f5504f53. No staging/reset/commit.

Recommendation: PL-1 no longer blocks closeout under this explicit in-flight-response contract. The bounded permission-lifetime increment is ready for user acceptance with the documented fixture/live distinctions and interrupted-session recovery tradeoff. No additional live race test is recommended; the deterministic fixture supplies the relevant ordering evidence. R1 acceptance remains unchanged. Future monitoring, streaming, remote configuration and query-proof goals remain deferred.


## November 9 — permission-lifetime increment accepted

Following the recommendation for acceptance after PL-1 reproduction, correction and focused verification, the user replied “ok proceed”. Record acceptance of this bounded permission-lifetime increment and closure of PL-1 under the documented contract: withdrawal prevents new response commitments; a response committed before withdrawal may still arrive.

Acceptance retains the evidence distinctions: earlier live Shortcuts exchanges were correlated; restart/network-switch retention and offline enablement followed by Shortcut success were user-confirmed; the final PL-1 correction has deterministic baseline-simulator fixture evidence and successful Mac/iPhone builds, with no live launch or request evidence for those final binaries. Interrupted-session recovery, persistence failures and credential/authority changes retain their fixture scopes. This is not a claim of a full-suite rerun, crash/power-loss durability, zero post-withdrawal arrivals, or a performance guarantee.

The increment is closed within this scope. R1 remains accepted independently. No additional implementation, deployment, live testing or future-service work is started by this acceptance. Existing sharing choices and protected profiles/history remain unchanged; no staging/reset/commit. Choose the next bounded product increment separately.
