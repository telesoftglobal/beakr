# Restricted shared status service: proof and selected-runtime integration

November 8, 2026. Post-R1 bounded increment, authorized after the read-only service-foundation assessment. R1 remains complete and accepted within its November 7 scope and evidence limitations.

## November 9 permission-lifetime update

The subsequently authorized persistent-permission increment supersedes the memory-only connection-scoped sharing descriptions below. Saved intent now survives ordinary disconnect and clean restart; transient capabilities and pending requests do not. Current verified membership/authentication remain mandatory. Offline withdrawal, credential/authority pinning and interrupted-session recovery are implemented. See [the current lifetime contract and 25 new fixture cases](Shared-Status-Shortcuts-2026-11-08.md#november-9-persistent-permission-lifetime-implemented). The original proof and November 8 live evidence below remain historical within their stated scopes; November 9 subsequently demonstrated a correlated authorized Shortcuts response after reconnect and denial after withdrawal. Offline enablement followed by successful Shortcuts execution, restart retention and network-switch retention are also user-confirmed. See the lifetime document for evidence distinctions and the final response commitment/withdrawal ordering correction and its deterministic test evidence.

## Current implementation boundary — November 8 integration

`Apps/Beakr/SharedStatusService.swift` implements a typed product snapshot, a restricted responder using the existing `DataDispatcher`, and a request client using the existing Data envelope and `HostDeliveryAttempt`. `Apps/BeakrTests/SharedStatusTests.swift` exercises them with injected transport, clocks, providers and temporary storage.

The initial isolated proof is now connected to the selected app runtime, following separate user authorization. `SharedStatusRuntime.swift` owns per-peer clients/responders and sharing choices; `SharedStatusSection.swift` supplies controls in remote-device details on Mac and iOS. `ApplicationLANRuntimeManager` constructs the adapter and a real read-only snapshot provider, and `NodeBootstrapModel` exposes it only for the selected profile. The provider returns the app bundle version, current running state and admitted peer count, with its sample time. No authority-hosting state is included.

**Integrated, fixture-tested, and observed in one user-operated Mac/physical-iPhone denial → allowed snapshot → denial exchange.** The live evidence below supersedes earlier pending-live statements. Screenshot inspection covers only the displayed controls/results, not a full layout or accessibility audit. The original isolated-proof results below remain scoped to that earlier phase.

### Live exchange — November 8, 20:05–20:10 EST

User authorized this bounded phase and replied “ok proceed” to the fresh prerequisite checklist, treated as confirmation: Network Link Conditioner off on both devices, XYZ selected on both, Mac XYZ authority Running and E8 Stopped. These hosting/NLC facts are user-confirmed, not independently measured by the agent. All app interactions were user-operated. Xcode BuildProject for physical 360-iPhone-Dev / iOS 27.2 passed at 20:02:44 (13.777 seconds); user then launched iPhone and Mac. The previous Mac build was not repeated as a separate agent check.

Console identity was verified before interpreting events, including platform-specific sender paths and loaded dylib UUIDs matched with dwarfdump against the build products:

| Platform | Launch reference / PID | OSLog session | Loaded Beakr.debug.dylib UUID |
| --- | --- | --- | --- |
| Physical iPhone, iOS 27.2 | 7c80f7c300 / 9065 | 9341CD58-7E27-4523-BB55-E1BD21C1E8D1 | 084A96EB-A314-3EC9-9FE4-0D6EF433DE77 |
| Mac | 7c79d90780 / 27722 | 049CAD35-64EF-47F8-8F86-4036857EB570 | CA30C42B-D5E3-3E8E-9D40-F012C3677D89 |

XYZ network ID was 53CEBC10-F471-49AE-A1FB-8313E0D23646. Mac node 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98 and phone node E8C3C596-8478-52E4-8577-FF194EC8C0B3 matched the displayed/admitted peers. Both consoles were retrieved by explicit launch reference; their metadata continued to match these platforms, PIDs and image UUIDs.

| Local time | Request correlation | Observation | Requester elapsed |
| --- | --- | --- | --- |
| 20:05:15 | 49E11D68-EEBC-4672-B554-456E83D104A4 | iPhone requests Mac with sharing off: Mac authorization denied, iPhone remote unauthorized; screenshot shows denial | 11.027333 ms |
| 20:06:56 | 7EB866FF-59AA-479B-9245-E6CECDA7369A | Additional user-operated reverse request, Mac asks iPhone: denied by phone; Mac screenshot shows denial and its sharing toggle off | 10.014792 ms |
| 20:07:56 | DA9AB33C-1D9A-49AE-8A48-D0C417C5480F | After explicit Mac sharing enablement, iPhone asks Mac: authorization allowed and client completed | 7.877375 ms |
| 20:09:54 | 60B858AA-54F9-4531-966F-0F12048184C3 | Following instruction to turn Mac sharing off, iPhone asks again: Mac authorization denied and phone remote unauthorized; screenshot shows denial | 9.648625 ms |

The successful phone screenshot displays Beakr version 1.0, runtime Running, Connected Devices 1, sampled November 8 at 20:07:56, with the snapshot explanation. The phone's sharing toggle remains off in its supplied screenshots. Final denial replaces the previously displayed snapshot. Mac screenshot confirms controls are visible in the selected phone's details; the user initially requested in the reverse direction, so permission/request direction is a useful future usability review item. No UI wording or implementation change was made during this phase.

Mac status runtime stayed 65606276-BAEC-4F04-A9B1-573467D59A06. Phone status runtime IDs changed between observations (8455238E-D151-4530-8518-7B368E7FF9AA, 1069F7DC-3366-4E4D-AABE-9D3E4567D497, 8C3F4F07-D5D1-4C51-ACB6-23DD9E663B35). Their cause was not investigated in this bounded exchange. Results demonstrate per-request authorization and interoperability, not uninterrupted runtime continuity or an isolated same-binding withdrawal experiment. Individual elapsed values are client measurements, not synchronized cross-device latency or a performance benchmark.

Screenshots supplied in conversation at 20:06:11, 20:07:01 (Mac), 20:08:50 and 20:10:30 support the visual observations. Full status logs were retrieved without truncation (Mac five events, phone seven). No live membership revocation, profile changes, re-enrollment, simulator interaction, reset, history inspection, or new R1 check was performed. No source changes or test reruns were needed. Xcode remains on My Mac; both app sessions were running when last retrieved. General delegation, Siri/AI, broad accessibility acceptance, adverse-condition testing and performance benchmarking remain outside this phase.

### Additional Shared Status presentation — November 8, after live exchange

User authorized clearer directional wording and an additional menu presentation. The ellipsis Device Actions menu beside the Shared Status heading in remote-device details includes **Shared Status…**. On Mac it opens a menu-button-anchored popover; on iPhone it opens a bottom sheet with medium/large sizes. The presentation identifies the selected device. The Done action was removed after user visual review; use system dismissal. The existing inline section remains available.

Both presentations render the same SharedStatusControls view using the owning section's availability, permission, pending task, error and snapshot state. They invoke the same actions and retain existing profile/peer identity and binding-generation guards. There is one observation and one request owner, not an additional service client. Request entry also rejects a second request while one is pending. Opening or closing the additional presentation does not request status or enable/withdraw sharing; Dismissing the additional presentation closes only that presentation, and a pending request remains owned by device details. Cancel remains explicit. Leaving device details retains the existing cancellation behavior.

Request wording is now **Request This Device’s Status**; explanatory text starts **Allow this device to read my status**. Remote denial reads **This device hasn’t allowed you to read its status**. No service, wire protocol, runtime permission or persistence changes were made. ContentView passes the selected peer's display name to the shared section.

Xcode BuildProject passed for My Mac at 20:18:27 (7.521 seconds) and the authorized baseline iOS simulator at 20:18:43 (12.058 seconds). Only whitespace formatting followed these builds. No app launch, new live request, UI automation or passed service-test rerun was performed. These builds establish compilation; popover placement, sheet presentation and interactive shared-state behavior still require visual verification. Earlier live screenshots/results apply to the preceding inline UI. Xcode was restored to My Mac after building. Index remained unchanged; no staging/reset/commit.

### Direct iPhone member shortcut — November 8, 20:49 EST

To reduce navigation steps, the iPhone remote-member row now has a long-press context menu action named **Shared Status**. It presents the status sheet directly from the member list; opening device details first is unnecessary. The current-device row also offers Shared Status in its long-press menu, but disabled because this action targets a remote peer. The shortcut is also available for saved/offline peers, with the existing unavailable explanation and disabled service controls. It does not switch networks.

The root view owns presentation, scoped by profile and peer identity. The sheet uses the existing SharedStatusSection and its lifecycle guards, reads current member status from bootstrap rather than trusting the menu's captured online flag, and hides the redundant section heading and nested status menu. Opening the sheet neither sends a request nor changes sharing. Closing this standalone sheet ends its view-owned pending request; snapshots remain view-local and are not retained between separate visits. Runtime permission remains shared with the existing details UI and is not withdrawn merely by closing the sheet. No service or networking behavior was changed.

Baseline iOS BuildProject passed at 20:49:46 (12.205 seconds); Mac BuildProject passed at 20:50:15 (7.858 seconds). No simulator/app launch or live request was performed; the user subsequently supplied a screenshot at 20:52:19 showing the direct member-list sheet for MacMini-Ice-9, sharing off and the request control visible. Naming remains provisional for a later terminology review.

User screenshot review requested removal of the second Shared Status heading and Done button. The standalone sheet now keeps only the top title/device name. Shared Status sheets/popovers omit Done; iPhone uses system sheet dismissal and Mac uses popover dismissal. Existing inline details retain their section heading/menu. Final iOS baseline BuildProject passed at 20:54:15 (7.204 seconds), Mac at 20:54:25 (8.028 seconds). No app interaction or new live request was performed by the agent; the simplified presentation has not yet been visually rechecked.

User screenshot at 20:59:59 confirms the duplicate heading and Done are absent. A subsequent spacing-only adjustment removes the standalone iPhone form’s top scroll-content margin below the device name. Baseline iOS BuildProject passed at 21:01:43 (8.773 seconds); adjusted spacing awaits visual verification.

User accepted the tightened iPhone layout as good enough for now, deferring terminology improvements. Subsequently added the disabled Shared Status item on the current-device row for menu consistency. Physical iPhone destination BuildProject passed at 21:05:43 (10.696 seconds); no agent launch or interaction. The disabled item still awaits visual verification.

### User controls

In an online remote device's details, Shared Status offers:

- **Share My Status with This Device**, default off. This lets that specific peer request this device's version, selected-runtime state and connected-device count.
- **Request This Device’s Status**, an explicit one-time local request. The remote peer must independently allow sharing; requesting does not enable sharing in either direction.
- A Cancel action while waiting, or the returned fields and remote sample time, or a typed failure description. The result is labelled as a snapshot, not a live feed. An older app without the service may time out.

Sharing is memory-only and bound to the selected runtime and the admitted peer connection's lifetime. It is cleared on full peer disconnection, trust ineligibility, runtime stop, restart or network switch. Replacement transports that keep the same admitted peer context retain its route identity. Inactive-network/local-device details cannot grant remote access. Closing a detail view cancels its pending request; it does not withdraw an already enabled sharing choice. Switch the toggle off to withdraw that choice.

### Receive routing, permission and lifecycle integration

`ProfileConnectionRegistry` supplies an optional authenticated application callback with the peer identity captured during admission and a local `ProfileApplicationRoute` (UUID plus session ID). It runs only after the existing transport/session receive validation. Returning nil preserves the ordinary inbox path; status traffic returns false, meaning consumed without durable-storage acceptance/acknowledgement. Status bodies/results never enter chat history or its outbox. Ordinary text/read receipts retain their existing sink and acknowledgement behavior.

The route UUID survives a replacement transport in the same peer context and changes after the final transport disappears. Delayed old-route callbacks cannot remove a newer binding. Each service slot also has a separate binding UUID, which changes when eligibility is lost even if the registry route later recovers unchanged. Runtime commands require the UI's expected binding UUID, so a stale control cannot restore sharing after trust recovery or grant permission to a replacement connection. There are at most 64 service bindings and 64 observers per runtime; observation uses bufferingNewest(1).

Before use and before submission, route resolution checks both endpoints' eligibility through the existing signed membership directory and matches the admitted session. Snapshot disclosure additionally checks the current sharing revision after sampling and after route resolution. Registry submission accepts an expected route UUID and rejects substitution. These checks precede submission; permission withdrawal cannot retract bytes from a send already in progress.

Stopping the runtime closes the status adapter before other teardown awaits. Peer-route removal and revocation diagnostics invalidate affected bindings. A single per-runtime task observes the existing registry peer stream; existing trust-refresh and approximately two-second delivery-maintenance passes also revalidate bindings. There is no additional periodic network poll. Expired/ineligible trust blocks use immediately at resolution; otherwise-idle UI/pending state can reflect it on the next maintenance pass. No live revocation was performed to test this.

The view uses explicit profile/peer identity, an observed runtime-start revision, and view/request generations to discard stale asynchronous completions. Sharing and request results are owned by the adapter/view respectively, not by a second editable membership store. No preferences, membership migration, new credential, new listener or separate port was introduced.

### Integration evidence

The new `SharedStatusIntegrationTests` exercise the production registry, authenticated route owner and delivery driver over injected in-memory transports, alongside the real inbox and a disposable Data store. Authentication/revocation verification and route eligibility are fixture supplied; this is not new TLS/security certification.

| Test | Result/scope |
| --- | --- |
| registryRoundTripAndChat | Default denial; explicit sharing; attributed status; no chat persistence or storage ACK for status; ordinary chat persists and receives ACK; withdrawal denies subsequent reads |
| replacementRoute | Reconnection starts with sharing off; delayed UI grant and old-route teardown cannot affect the replacement |
| pendingInvalidation (2 variants) | Ineligible route or runtime stop terminates pending requests and clears sharing |
| inactiveSelection | An inactive profile cannot obtain the selected runtime's service |
| withdrawalDuringSampling, stopDuringSampling | Withdrawal or stop while sampling suppresses outgoing snapshot; originally one parameterized blockedDisclosure test |
| staleRouteSubmit | Registry rejects an unexpected route UUID before transport submission |
| deadlinePrecision | Allows only sub-millisecond serialization difference, rejects a ten-millisecond excess |
| trustRecoveryPermission | Loss/recovery of eligibility on the same registry route creates a fresh default-off binding and rejects an old UI permission command |

Ten distinct new integration scenarios passed. Baseline BuildProject with tests passed at 18:48:05, 18:49:28, 18:50:53 and, after the final binding-ID/test updates, 18:53:54 and 18:54:39. Final Mac BuildProject passed at 18:54:56. An initial 18:45:01 build failed on a missing BeakrNetData view import, corrected before testing.

The first test run at 18:48:12 had four passes and one failure: real-clock dates exposed a deadline precision mismatch absent from the fixed-clock proof. The Data deadline is encoded in milliseconds while an in-memory envelope can retain a slightly more precise Date. Expiry/deadline comparison now allows at most 0.001 seconds of serialization difference, while actual expiry and the client's ten-second monotonic deadline remain enforced. The failed roundtrip passed at 18:48:33 after correction. The 18:49:34 run passed four reported cases (both blockedDisclosure variants, staleRouteSubmit, and existing invalidRequests argument 0); do not infer that all invalidRequests variants reran. The 18:51:13 run passed four reported cases (deadlinePrecision, blockedDisclosure false, and both pendingInvalidation variants) after closure cleanup on invalidation. Passed checks were revisited only for changed validation/assertions or cleanup behavior; no full suite was run.

Integration test summaries under `ActionArtifacts/4217D839-B9D4-4398-A0DD-4C3422C07B03/RunSomeTests`: `6A7CB872-38E1-4A80-BD6A-724B12D7A094.txt` (initial failure), `AC813DD7-D6F8-4144-87AE-E3160C79EFEE.txt` (fixed roundtrip), `5969EDC4-3A55-4684-96C7-4E64A4A12EA9.txt`, `CF9F998B-A32D-4D01-9A99-3DA34EC4EACF.txt`. Baseline UUID/name/runtime were reverified from device.plist before testing. No physical phone/Mac app interaction, live membership operation, console retrieval or UI automation occurred; Xcode is left on the authorized baseline. Visual layout/accessibility and live interoperability remain unverified.

Final binding-ID validation at 18:54:14 passed nine reported cases, including same-route trust recovery (`F4875706-DA0E-41EA-8FB8-A44FFC4A6D15.txt`). Xcode reported only the false variant of blockedDisclosure in that selection, so its two variants were split into named test entry points to make execution explicit. The missing final stop-during-sampling scenario then passed 1/1 at 18:54:45 (`91E86E8D-3496-4801-A3AD-809F707FEC3E.txt`). These final nine plus one results cover the ten scenarios; the existing invalidRequests argument 0 check is additional, not counted as a new scenario. A test-discovery/tool serialization call failed during that split; no test result is claimed for that call.

## Existing foundations and reuse

| Component | Existing responsibility | Disposition |
| --- | --- | --- |
| BeakrNetData | Canonical Data codec, requests/replies, correlation, deadlines, cancellation vocabulary, dispatcher authorization and optional persisted results | Reused; no new transport protocol |
| PersistentHostMessagingService | Durable enqueue, stable-envelope retries, acknowledgements; default 30-day envelope lifetime | Preserved for messaging; short-lived status requests do not enter this queue |
| Authenticated host connection path | Transport/session acceptance before the incoming application sink | Integrated through a separate status callback; fixtures do not certify TLS/admission |
| Blackboard | Space-level membership, authorized snapshots, replication and persistence | Preserved; not required for this on-demand status sample |
| Transfer | Bounded resumable staging, integrity and publication | Preserved; not required for a small response |
| Operations | Authority-oriented admission limits, bounded event journals and counters | Preserved; not treated as a general Actor grant/audit implementation |

The October 25 Permissioned Networking Contract remains a proposal. This increment does not implement its general Actor, ServicesProfile or ServiceBinding persistence models. `SharedStatusBinding` is an internal immutable runtime/peer/session binding, not a credential or signed grant.

## Operation and information scope

Operation: namespace `beakr.status`, name `read`, version `1`; Data kind `request`. The request body is empty and idempotency keys are disallowed. The requester cannot name a file, query, resource path, remote Actor or additional fields.

The response contains only:

- `schemaVersion` (1).
- `sampledAt`, supplied by the trusted read-only provider.
- `applicationVersion`, nonempty and at most 128 UTF-8 bytes.
- `runtimeState`: starting, running, stopping, stopped or failed.
- `authenticatedPeerCount`, a nonnegative count without identities.

Responses are at most 4 KiB of body data; the canonical Data payload limit is 8 KiB to accommodate metadata and base64 encoding. This is not the limit on a complete encoded network frame. The response contains no message history, paths, addresses, peer names/IDs, credentials, other memberships or authority administration state.

The client returns local provenance alongside the snapshot: its immutable binding, correlation ID, local receipt time and monotonic elapsed duration. The authenticated envelope establishes the peer source; a remote body cannot replace it. Sampling time is a peer assertion, not a clock-synchronization guarantee or independent attestation.

## Permission and lifetime

Both ends default to disabled. Trusted local composition must explicitly enable the fixed operation for one binding: runtime ID, network, local node, remote node and session. This local restriction only narrows existing transport eligibility. Node IDs passed to these APIs are not proof of authentication; the future adapter must obtain them from the accepted connection, not the request body.

The responder checks authenticated peer against envelope source, expected peer, network, destination and session before invoking the dispatcher. It also validates the envelope, ephemeral delivery, operation, empty body and bounded deadline. The dispatcher receives a restrictive policy for that peer, operation and request kind, rather than its permissive default. The responder owns a separate dispatcher for its binding and remembers at most 64 completed message IDs.

`setEnabled(false)` withdraws the local restriction's permission. `invalidate()` permanently closes the instance for runtime replacement. A revision check after sampling suppresses a reply if permission changed or the runtime was invalidated during an await. A future send adapter must also check its binding immediately before transmission; returning a response object is not a network write.

One request per client and one provider invocation per responder may be outstanding. Composition must bound the number of bindings when live integration is added; this proof is not an unlimited peer registry. The injected provider must be small and cooperative. An uncooperative provider cannot be forcibly stopped; its eventual result is suppressed after withdrawal/invalidation/expiry.

## Outcomes, offline behavior and cancellation

Requests use ephemeral envelopes with a ten-second expiry and Data deadline. The client has a ten-second monotonic timer and independently checks elapsed time when receiving a reply. The responder rejects expired requests and checks deadline/expiry again after sampling. Cross-device wall-clock skew can cause rejection; elapsed timing does not infer synchronized clocks.

The injected send closure performs an immediate eligible-route attempt and returns `HostDeliveryAttempt`. No route or a send failure returns unavailable. There is no durable status queue, automatic retransmission, restart recovery or retained status result. Repeating the user's read creates a fresh correlation and sample. Duplicate completed request envelopes are rejected by the bounded dispatcher history, and duplicate replies cannot complete an already finished client request.

Only a valid response/application error from the expected network, peer, destination, session, operation and correlation may complete a request. Transport submission and delivery acknowledgements are not service success. Malformed/unrelated envelopes are ignored until another reply or timeout; a matching response with an invalid snapshot completes as invalidResponse.

Client outcomes distinguish unauthorized, busy, unavailable, timedOut, cancelled, invalidated, invalidResponse and remote application error. Local task cancellation ends waiting and cancels local send/timer tasks; it does not retract already transmitted data or guarantee remote sampling stops. This proof sends no remote cancellation packet. Disconnection, permission withdrawal and runtime replacement terminate pending work; late callbacks cannot complete a subsequent request.

## Narrow DataDispatcher correction

Inspection found that the dispatcher marked a Message ID seen before handler completion/persistence and cached idempotency results before their durable save succeeded. A failed handler/save could therefore suppress a valid retry or expose a cached result that had not been saved.

The dispatcher now:

1. Tracks bounded in-flight Message IDs and idempotency keys to prevent overlapping handler execution across actor suspension.
2. Releases in-flight reservations on every return.
3. Adds replay history and successful idempotency results only after successful handler validation and optional persistence.

Overlapping work receives resourceLimit. A failed attempt can retry the same envelope. Successful stored responses retain existing restart behavior. This does not provide atomicity between an arbitrary handler's side effects and result persistence: mutating handlers remain responsible for idempotency. The status provider is read-only. The generic dispatcher is not itself a session authenticator or cross-peer permission framework.

The service proof deliberately uses no persistent result store. Separate tests exercise the dispatcher's existing persistence seam using disposable repositories and an obstructed parent directory, without accessing app history. No new storage schema or migration was introduced.

## Observability

An injected structured event sink reports request start, responder permission decision, ignored reply and terminal outcome. Events include runtime/correlation IDs and local elapsed duration when available. Client failures use typed categories. The runtime adapter emits these through the existing Runtime OSLog category with `[STATUS]`. Events contain no snapshot body or credentials; they are diagnostics, not authorization evidence or a mandatory durable audit trail. The components retain no separate event history. Verify console platform/session/PID and loaded build before interpreting a future live trace.

Measurements establish per-request elapsed time, not LAN latency alone, throughput, availability guarantees or a statistical performance benchmark. Provider execution, scheduling and transport all contribute.

## Initial isolated-proof acceptance and evidence

Xcode BuildProject passed for the authorized baseline simulator with test targets at 18:09:34 and, after the final event/test additions, 18:11:59. My Mac BuildProject passed at 18:12:57. An initial 18:09:15 build failed solely because the new tests lacked the BeakrNetHost import; that import was corrected before execution.

Focused tests: 22/22 passed at 18:09:41; 5/5 passed at 18:12:08 after adding overlapping-dispatch/invalid-reply cases and extending the timing assertion. This is **26 distinct cases**, with one timing case repeated because its assertions changed. No full-suite result is claimed. Runs used Beakr / Beakr-R1-Contract-Baseline-20261026, UUID E40CDB24-C697-4F57-8F87-CBFD9DFADDD5, iOS 27.0, verified from its device.plist before testing. Xcode was returned to that destination after the Mac compile. No Mac/phone app launch or console retrieval occurred in this phase.

Artifacts are under `ActionArtifacts/4217D839-B9D4-4398-A0DD-4C3422C07B03`: RunSomeTests summaries `AFD106BE-B98C-4711-8CED-7C6F72D1A125.txt` and `6016DC7C-5D55-4A02-A690-70A8416B3CB1.txt`, and the dated BuildProject logs. Those temporary artifacts are supporting evidence; this record retains their scope and outcomes.

| Acceptance | Focused test evidence |
| --- | --- |
| Authorized bounded reply with provenance | roundTrip |
| Default denial and authenticated binding isolation | defaultDenied, bindingDenials (5 variants) |
| Empty request, size and deadline restrictions | invalidRequests (4 variants) |
| Withdrawal/replacement while provider awaits | responderInvalidation (2 variants) |
| Matching, duplicate/late suppression, busy outcome | replyMatching, lateReply |
| Local cancellation, unavailable, invalidated, permission withdrawal | terminalOutcomes (4 variants), offlineAndTimeout |
| Remote application error versus invalid snapshot | invalidReplies (2 variants) |
| Correlated terminal timing and typed failure | lateReply |
| Retry after handler/save failure; restart replay | failedHandlerRetry, failedPersistenceRetry |
| Bound overlapping message/key execution | dispatcherInFlight (2 variants) |

These are isolated component tests with injected transport and authenticated-peer context. They do not establish live authentication, live cross-device timing, UI permission flows, actual device snapshot contents or unsolicited access to another device. Protected profiles/history and iPhone 18 Pro are excluded. Existing accepted R1 checks are not reopened.

## Next bounded phase

The bounded user-operated Mac/iPhone exchange is complete within the evidence limits above. No additional implementation or device testing is authorized by completion. The subsequently authorized presentation increment above implements clearer wording and an additional menu presentation; visual verification of that new presentation remains pending. Agree the next bounded scope separately; do not reopen accepted R1 checks.

Siri/AI callers, arbitrary reads/actions, generic delegation, mandatory audit gates, dashboards, simultaneous multi-network participation, Host/Co-Host roles, Blackboard synchronization, bulk transfer and radio/relay workflows remain outside this increment.


### November 9 live Shortcuts progress

One authorized Shortcuts snapshot after phone background-stop/reconnect is now verified by user screenshot and matching Mac/iPhone logs, correlation61F0604D-463F-40FE-B733-7EC833386623 at15:50:53. This supersedes earlier unproven-success statements; offline withdrawal/denial remains pending. See the latest [Shortcuts evidence](Shared-Status-Shortcuts-2026-11-08.md). No additional R1 acceptance scope or restart/crash recovery claim.


### November 9 live permission-lifetime result

The bounded Mac/physical-iPhone Shortcuts check is complete: default denial, explicit sharing, successful authorized snapshot after phone background/runtime stop/reconnect, then user-confirmed offline withdrawal followed by verified denial. This supersedes earlier pending/unproven live-success statements. See [the full sequence and evidence limits](Shared-Status-Shortcuts-2026-11-08.md#november-9--bounded-permission-lifetime-live-check-complete). Restart/crash recovery, save failures and identity changes retain their separate fixture-only evidence; no broader live certification or new feature scope is implied. R1 remains accepted.
