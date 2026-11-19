# R1 networking: repeatable adverse-condition acceptance

This supplements A1–A12; it does not rename or replace the original checklist. The saved A-Series observations record supplied evidence, not complete certification. Re-run the original cases on the rebuilt Mac, physical iPhone, and simulator, then run the cases below. A passing unit test or green peer count is insufficient to sign off hardware behavior.

## Console conventions

| Marker | Meaning | What it does not establish |
| --- | --- | --- |
| 🔴 `[FAIL]` | An operation failed; app logs use error severity. | An automated test failed. Negative tests deliberately exercise errors. |
| `[RETRY]` | A retry is scheduled, or the handoff lab is exercising retry behavior. | Recovery has completed. |
| `[RECOVERED]` | A recovery transition or verified repair occurred. | Every peer is reachable or messages are delivered. |
| `[INFO]` | An ordinary lifecycle or operational event. | Test acceptance. |
| `[TRACE]` | Detailed debugging, including repeated authority requests and indicator changes. | A problem requiring attention. |
| `[PASS]` | A console tool completed its stated checks. | The entire A-Series passed; fixture generation is not a networking test. |

In Xcode, filter the Connectivity, Runtime, Enrollment, Authority, and Delivery categories or search the markers. Routine traces use debug severity; failures use error, not artificial fault escalation. Apple networking/system messages retain their own formatting. Private details can be redacted in exported unified logs; the fixed markers remain visible. Never attach invitation secrets, key material, or fixture environment files to a result report.

Shell scripts share `Scripts/console-diagnostics.sh`. Errors are red on an interactive terminal, and labels survive redirected output without ANSI escapes. `NO_COLOR` disables colour. CLI tools preserve the raw `identity` command output and help text; operational messages are labelled, and terminal failures exit nonzero. Automated test assertions remain the source of test pass/fail results.

## Run protocol

1. Record build revision/workspace state, OS versions, device names, network, authority state, and test ID. Confirm all devices use the intended rebuilt version.
2. Establish a baseline: two remote peers per device and successful messages both ways between each pair. Use unique message subjects containing the test ID and sequence number.
3. Change one condition at a time. Record the action time, observed failure, retries, recovery time, and message outcomes on all relevant devices. Keep authority logs alongside peer logs.
4. During automatic-recovery cases, do not use Refresh, Forget, QR re-enrollment, or profile reset. If manual intervention is needed, record the automatic run as failed before using it to diagnose.
5. After restoring the condition, observe for 60 seconds and record actual recovery latency. This is an acceptance observation window, not a promised SLA. A failure to recover within it needs investigation; do not silently extend the window until the test passes.
6. Verify recipients, final delivery status, and exactly one received copy per message. For trust-negative cases, verify rejection and no delivery instead. Check history remains in the correct network.

## Adverse cases

| ID | Disturbance | Required evidence |
| --- | --- | --- |
| E1 | Stop the authority, cold-start previously enrolled peers, exchange messages, then restart the authority. | Valid cached trust permits the expected existing-peer operation; authority retries are bounded; automatic trust refresh resumes. Record behavior separately once cached credentials expire. |
| E2 | With authority unavailable, try to introduce a newly approved member unknown to an existing peer; restore authority. | Unknown membership is rejected during the outage; signed refresh later admits it without manual Refresh or an authentication storm. |
| E3 | Foreground iPhone while authority is unavailable, then background it during startup, then foreground again. Repeat at different points. | No superseded startup publishes connected state, no duplicate runtime, eventual recovery and successful message exchange. Automated debounce/start interruption coverage supports but does not replace this run. |
| E4 | Disable Wi-Fi or disconnect the access point; restore it. Repeat briefly and for several minutes. | Peer counts and delivery status reflect lost paths; retries remain bounded; queued messages arrive once after recovery. Record cellular availability separately. |
| E5 | Force-stop a peer, relaunch, and repeat; separately test normal Quit/backgrounding. | Unannounced and announced departures remain distinguishable; old endpoints/callbacks do not displace the current connection; unrelated peers continue communicating. |
| E6 | Start two peers simultaneously, then perform 20 rapid background/foreground or stop/start cycles. | No duplicate peers/messages, no progressively increasing recovery delay, and no unbounded connection/task/resource growth. Record memory and CPU before and after settling; compare trends rather than treating one noisy sample as proof. |
| E7 | Switch Hamilton/Queens while reconnection or message submission is pending. | No cross-network recipient, history, delivery, or late callback contamination. Verify both networks independently after switching back. |
| E8 | Approve a join, then terminate the joining app before completion; relaunch. Also try repeated scans while pending. | Durable request resumes once; no duplicate membership or repeated installation; the join sheet closes only after successful completion. |
| E9 | On disposable test membership, remove a member while that peer is offline, then reconnect it after verified revocation refresh. | Other peers exclude it and reject its old credentials, including after restart. Before refresh, document the cached-trust window rather than claiming instantaneous push revocation. |
| E10 | Deny Local Network permission, attempt startup, then enable permission and return to the app. | Actionable failure, bounded attempts, and recovery without resetting identity; verify real hardware because simulator permissions differ. |
| E11 | With a controlled test network, introduce latency, packet loss, and intermittent authority access. Record the actual impairment settings. | Retries stay bounded, UI remains responsive, message IDs/delivery state survive ambiguous sends without duplicates, and recovery needs no manual refresh. Do not change the production network for this test. |
| E12 | Use disposable fixtures for expired/revoked/wrong-authority credentials, corrupt persisted snapshots, and invalid signatures. | Fail closed with useful diagnostics; no unauthenticated message acceptance and no replacement of verified cached state by an invalid response. Do not alter the real device clock or production trust files. |
| E13 | While Hamilton has connected peers and ongoing message exchange, create a differently named test network on the Mac. Then explicitly choose Make Active for it and switch back. | Creation leaves Hamilton selected, its authority/listener running, and messages flowing. The new network appears inactive. Only Make Active switches networks. A creation failure must leave Hamilton connected and remove only the failed new setup. Also verify that first-network creation on a clean disposable installation still activates automatically. |
| E14 | Change a device Friendly Name during active messaging; observe, restore the name, and repeat on each supported platform. | Name propagates without changing identity/membership/history; path and peer monitoring resume; stable connectivity and bidirectional delivery persist for five minutes without Refresh or foreground recovery. |
| E15 | Inspect saved memberships while another network remains selected for messaging; switch networks and return. | Per-network member and local-node identities remain isolated; inactive presence is unknown, stale/unavailable data is labelled, and viewing does not start messaging/hosting or alter memberships/history. |

The first priority is E2–E5, E7–E9, and E13 alongside the four current R1 checks. E1, E6, E10–E12 broaden confidence before declaring the foundation complete. Any data loss, cross-network delivery, unauthorized admission, unbounded retry loop, or required manual recovery blocks signoff until understood and retested.

## Next acceptance procedures — October 31

Status: prepared, NOT RUN. These procedures add no new acceptance passes. Execute E8, then E2, then E9; E9 intentionally revokes only the explicitly designated disposable membership. Keep the existing XYZ results and historical failures above/below intact.

### Topology and execution boundary

Record the exact simulator name and identifier before starting; iPhone 17 and iPhone 17 Pro have both been live XYZ participants. An available simulator is not automatically disposable. Automated app tests remain restricted to Beakr-R1-Contract-Baseline-20261026.

Use a separately named test network, for example R1-E829-<run timestamp>, with authority A, established observer B, and disposable joining member C. Record network ID and each node/profile ID; display names alone are insufficient for removal. Create new memberships only for this test network, preserving all existing profiles and identities. Do not remove/re-enroll XYZ members or reuse an existing live membership as C. A/B/C device assignment and permission to interrupt their apps must be settled before execution.

Only the selected active network hosts its authority. Using the current Mac as A therefore temporarily takes its authority service away from XYZ when the test network is activated. Schedule that explicitly or use a separate disposable authority environment; do not assume the test network can run alongside XYZ authority hosting. Return the Mac to XYZ afterward and verify messaging. Do not delete the test network or its evidence as cleanup.

For each phase, record build/workspace state, device/OS, action timestamps, request/node/network IDs, signed membership/revocation generations where available, and uniquely labelled messages. Never include invitation tokens or private keys. Use the existing 60-second recovery observation window; record intervention separately. Two remote peers is the three-member baseline only, not an expected count during intentional outages.

### E8 — interrupted enrollment and repeated pending import

1. Establish A/B messaging on the disposable network. Generate a fresh invitation for C, submit it, and record its pending request ID and node ID on A. While pending, import the same invitation again where the UI permits; verify the request/node remain the same and no extra membership appears. A different fresh invitation exercises replacement, not same-request deduplication.
2. Deterministic pending-recovery variant: terminate C while still pending, then approve that exact request on A while C is stopped. Confirm A records approval without device confirmation. Relaunch C with authority available; do not rescan or Refresh.
3. Verify saved-request recovery, one installed membership for C, eventual Registered authority history, successful root navigation, and one copy of E8 messages each way with A and B. Capture recovery time and any failures.
4. The matrix's narrower approved-during-install interruption remains separate: with another fresh disposable membership, approve while the joining app runs and terminate it before installation completes. Record the observed phase. If installation already completed or the timing cannot be established, mark this variant NOT ESTABLISHED rather than counting an ordinary relaunch as a pass. Do not repeatedly reset/re-enroll C to hit the timing window. A controlled disposable debug/test checkpoint is the next option if manual timing is inconclusive.
5. On failure, retain the request and diagnostics; do not replace the invitation or clear the profile before recording the result. A single row in the UI supports membership deduplication but does not by itself prove installation executed exactly once.

### E2 — unknown member while authority is unavailable

Use a fresh joining membership for this phase: a peer already admitted during E8 is no longer unknown to B.

1. With A and B established, record B's verified membership generation and member list. Stop B before approving the new C membership. Keep B stopped throughout approval/installation so it cannot fetch the newly published membership.
2. Complete C enrollment with A and record the new member ID/generation. Quit A's authority app before reopening B. Leave C running. Confirm no other process serves this test authority.
3. Reopen B with A unavailable. Capture evidence that B still lacks C and that an attempted C connection is rejected for unknown membership. Observe bounded retries for 60 seconds and no unauthorized delivery. If B already knows C, or no authentication attempt reaches B, the trust-negative condition was not exercised; do not call it a pass from an Offline indicator alone.
4. Restart A on the same test network. Leave B/C running, with no Refresh, rescan, or restart. Within the recovery window, capture verified trust refresh and admission, then send E2-labelled messages both ways between B and C and check one received copy and sender delivery status.
5. Record rejection during outage and automatic admission after restoration separately. Cached-trust expiry, unrelated transport failures, or a missed unknown-member precondition make this run inconclusive for E2 until distinguished.

### E9 — revocation convergence of the designated disposable member

1. After E2, establish A/B/C delivery and record C's exact test-network/node/profile identity and credential identifier if available. Stop C without deleting its saved profile or credentials.
2. At the removal step, verify the selected row matches the designated disposable membership. Removal requires authorization for that specific test membership; this procedure does not authorize deleting any live membership. Remove C through the authority's supported UI and record the resulting signed revocation generation/time.
3. Leave B running and observe automatic maintenance separately. Record the interval before B verifies revocation as a cached-trust window. Do not infer push invalidation or instantaneous convergence. If it does not refresh within 60 seconds, record that observation; scheduled maintenance may require longer. If an explicit refresh/startup is then used to establish the post-refresh condition, label it as intervention, not automatic convergence.
4. After evidence that B has verified C's revocation, reconnect C with its unchanged saved identity. Verify exclusion and no accepted C-to-B delivery; test B again after restart to check persistence.
5. Distinguish C refusing locally after learning its own revocation from B actually rejecting a presented old credential. If the app prevents C from attempting authentication, record local fail-closed behavior only; peer-side old-credential rejection still needs the disposable signed integration fixture or equivalent controlled evidence. Do not modify live trust files to force the attempt.
6. Preserve audit/revocation evidence and C's revoked test profile. No re-enrollment or deletion is needed to finish this case. Restore the original active networks and verify XYZ messages without changing XYZ memberships.

Resource-growth measurement, controlled impairment, negative trust fixtures, creation-failure/clean-install variants, and independent authority hosting remain open. These procedures do not expand R1 into general mesh or concurrent messaging.

## Automated evidence added October 30

Focused regressions now cover prolonged membership outages reaching the retry cap and resetting after recovery; an offline/invalid-signature sequence preserving the last verified file; and a newly verified revocation taking effect even when the following membership fetch is offline. Existing tests cover authentication backoff, stale discovery generations, duplicate changes, cancelled connections, revoked peers, and foreground interruption. These tests use controlled clocks/fakes and disposable trust state; they do not model radio behavior, OS suspension, or all timing interleavings.

## Result record

### E1 observation — XYZ, October 30

User reported successful message exchange while the authority Mac was shut down and after it started again, following the requested E1 procedure. The reported result supports messaging between the remaining iPhone/simulator during the outage and across all three devices after Mac recovery. Messaging portion: user-confirmed PASS. Full E1 acceptance remains open: peer cold-start execution, no-Refresh recovery, recovery time, duplicate counts, bounded authority retries, and verified trust-refresh resumption were not separately reported. Expired-cache behavior was not tested. No exact build identifier or action timestamps were supplied for this run.

Follow-up: the user answered the explicit relaunch/no-Refresh/60-second question by confirming both peers were relaunched and recovered to green immediately, followed by immediate recovery on Mac relaunch. Cached-trust cold-start messaging and automatic recovery: user-observed PASS. This resolves the peer cold-start and no-Refresh questions above; latency is qualitative rather than measured. Duplicate counts, bounded retry telemetry, verified trust-refresh resumption, and expired-cache behavior remain unverified.

### E3 observation — XYZ, October 30

Procedure requested: quit Mac Beakr; open iPhone Beakr and immediately background during startup; return and repeat three times; exchange messages with the simulator without Refresh; relaunch Mac. User reported no aberrant behavior, all messages exchanged, and immediate green status on Mac startup. User-observed behavior: PASS for this run. Exact interruption phases, runtime/task counts, and latency were not instrumented; no claim of exhaustive timing-interleaving coverage.

### E4 observation — XYZ, October 30

Following the requested Wi-Fi outage/restore procedure, user reported recovery with queued messages delivered to the iPhone within 5–10 seconds. Recovery and queued delivery: user-confirmed success within the 60-second observation window. Exactly-once receipt, successful reply, outage duration(s), cellular availability, and no-Refresh recovery were not separately confirmed. E4 remains partially verified; no claim that both brief and prolonged outages were exercised.

E4 follow-up: user answered the single-copy/reply question affirmatively and explicitly confirmed no Refresh was required and messages were delivered immediately. Automatic recovery and delivery are user-confirmed successful for this run. Preserve the earlier 5–10-second recovery estimate; immediate delivery does not establish zero recovery latency. Outage duration and cellular availability remain unspecified, and no separate per-message evidence was supplied. Do not infer that both brief and prolonged outage variants passed.

### E4 prolonged outage — FAIL, October 30

User reported first Send after five minutes delivered to iPhone-17 only, while messages to Mac and iPhone-17 Pro stayed queued four minutes after Wi-Fi restoration. This exceeds the 60-second acceptance window and blocks E4 signoff. Exact sender/device topology and current peer states await clarification. Mac console showed a replacement outgoing connection stuck preparing after posix-60 failure; added a 15-second establishment deadline with existing bounded retry backoff and regression coverage. Tests/builds passed, but no rebuilt-device rerun has occurred and the complete cause of all queued messages remains unproven. Preserve this failed run separately from earlier successful recovery.

Sender clarification: the physical iPhone sent the messages. iPhone-17 received the first; Mac- and iPhone-17 Pro-destined messages remain Queued in the physical iPhone Outbox. Four devices are referenced in this run. Current sender-side Online/Offline state for the stalled destinations is pending; Mac logs alone cannot establish sender-side retry behavior. No live restart or queue change performed.

User subsequently confirmed both stalled destinations show Offline on the physical iPhone. Record missing peer connectivity rather than an apparently Online delivery stall. Proposed diagnostic is rebuilt-Mac-only relaunch while preserving sender and simulator state; any recovery after that intervention does not turn this failed automatic-recovery run into a pass. Updated-device prolonged-outage retest remains required.

Diagnostic outcome: following the rebuilt-Mac-only relaunch, user confirmed XYZ came online and the existing iPhone-to-Mac queued message was delivered immediately. Queue retention/delivery after route restoration succeeded. This was restart-assisted recovery, not proof of automatic timeout recovery; prolonged E4 remains FAIL pending a fresh no-intervention run. iPhone-17 Pro queued delivery remains unconfirmed.

Second diagnostic outcome: user confirmed restarting iPhone-17 Pro delivered its existing queued message from the physical iPhone. Both stalled destination queues recovered after destination restarts. Exact simulator build was not independently verified. Prolonged automatic recovery remains unvalidated; repeat with the timeout-fix build on every participating device and no manual recovery during the observation window.

### E4 prolonged-outage retest — user-observed PASS, October 30

Requested procedure: latest build on all participants, five-minute physical-iPhone Wi-Fi outage, three distinctly labelled messages to Mac/iPhone-17/iPhone-17 Pro, then restore Wi-Fi and return to Beakr without Refresh or restart, observing for 60 seconds. User confirmed all three messages arrived immediately after Wi-Fi became enabled. Automatic recovery and queued delivery: user-observed PASS for this retest. Timing is qualitative; exact build identifiers, duplicate counts, cellular availability, and retry/resource telemetry were not independently captured. Preserve the original failed run and restart-assisted diagnostics; this retest does not certify other adverse cases.

### E5 forced iPhone termination — user-observed PASS, October 30

Requested procedure: force-close Beakr on the physical iPhone, queue a Mac-to-iPhone message, then reopen; verify automatic reconnection, single delivery, and continuing simulator communication. User reported the check passed, specifically confirming immediate message delivery after iPhone startup. Record this forced-iPhone variant as user-observed PASS. Timing is qualitative; separate message identifiers, counts, and departure-classification logs were not supplied. Other E5 variants and repeated-cycle/resource checks remain separate.

### E7 queued-message network switching — user-observed PASS, October 30

Requested procedure: physical iPhone switches XYZ -> Hamilton; Mac stays on XYZ and queues XYZ-only-1 to the offline iPhone; verify no delivery/history in Hamilton; switch iPhone back to XYZ without Refresh and verify one delivery only in XYZ history. User reported Passed, immediate delivery. Record user-observed PASS for this variant. Exact timing and separate per-message evidence were not supplied. Switching the sender during submission and other pending-reconnection interleavings remain separate.

### E13 creation continuity — user-observed PASS, October 30

Requested procedure: keep XYZ active, create a uniquely named network on Mac without choosing Make Active, exchange XYZ messages during/after creation, and verify the new network remains inactive. User reported Pass: messages delivered and the Unique network remained InActive. Record the creation-continuity portion as user-observed PASS. Explicit activation/switch-back, creation-failure continuity, and clean-install first-network creation were not part of this hardware run.

E13 follow-up: user reported Pass, immediate delivery for Mac explicitly activating Unique, other devices continuing XYZ messaging, then Mac returning to XYZ without Refresh and exchanging messages both ways with iPhone. Normal creation/activation/return flow: user-observed PASS. Recovery timing is qualitative; creation-failure and clean-install first-network hardware variants remain separate.

### E10 permission denial — presentation FAIL; recovery succeeded, October 30

User denied Local Network permission on physical iPhone. Background/foreground showed blue and one device online; app restart showed Finding devices then 1 Device Online. No actionable permission message appeared. After enabling permission and returning to the app, it became green within five seconds without Refresh. Recovery: user-confirmed success; denied-permission presentation: FAIL. Message exchange and retry bounds were not separately supplied.

Implemented explicit DNS/POSIX permission-denial classification and per-runtime propagation to a distinct red permission-required UI state. Focused model regressions and Mac/iOS builds passed, including recovery and preserving denial through peer reconciliation. Await rebuilt-iPhone denial/restore UI and message-delivery retest before closing E10. No identity reset or re-enrollment.

### E10 rebuilt-iPhone retest — presentation/recovery PASS, October 30

User confirmed the requested rebuilt-app permission off/return/on check passes: immediate red display with Local Network permission off, immediate green when enabled. Record user-observed PASS for actionable denial presentation and automatic recovery, preserving the original failed presentation run above. Timing is qualitative. Message exchange after this permission cycle and bounded retry/resource evidence were not separately supplied; this result does not close all E10 evidence requirements or R1.

E10 messaging follow-up: user reported Pass, messages sent in both directions, following the requested XYZ iPhone/Mac one-message-each-way check without Refresh and with single receipt. Record user-observed PASS for post-permission-recovery messaging. The affirmative response covers the requested procedure; separate message identifiers and instrumented counts were not supplied. Hardware presentation, automatic recovery, and messaging checks have now passed for this retest; bounded retry/resource evidence remains separate.

### E6 repeated lifecycle observation — October 31

Requested procedure: keep Mac/simulators on XYZ, background/foreground physical-iPhone Beakr 20 times without Refresh, exchange messages with Mac, and watch for duplicate devices/messages, stuck status, or progressively slower recovery. User reported 20+ cycles and message exchange at the conclusion. Post-cycle messaging succeeded. Duplicate/stuck-state/delay observations and absence of Refresh were not explicitly confirmed in this reply. Simultaneous peer startup and CPU/memory/task trends were not measured; full E6 remains partially verified.

E6 follow-up — October 31: user explicitly confirmed no duplicates after the 20+ cycles. Record the no-duplicates check as user-confirmed success. Stuck-state, progressive-delay, and Refresh-use observations remain unconfirmed; resource telemetry and simultaneous startup remain separate.

E6 timing follow-up — October 31: user answered the prompt-recovery/no-stuck-state/no-Refresh question affirmatively, qualifying that app status displayed promptly on most background/foreground transitions but slowed by approximately five seconds toward the end. Combined observations: 20+ cycles, no duplicates, successful concluding message exchange, and automatic recovery. Preserve the late-run delay as an unresolved possible progressive slowdown, not a clean pass of the E6 latency criterion. It is not yet established whether the delay affected status rendering, peer reconnection, or both; no resource measurements were captured. Next diagnostic: leave the app foregrounded for one minute, then perform three spaced background/foreground transitions and observe status timing. No code or live-device changes made.

E6 settled follow-up — October 31: after the requested one-minute foreground settling period and three spaced background/foreground cycles, user reported no problems and attributed the earlier delay to network reconnection reaching green within five seconds. Record user-observed PASS for the exercised repeated-cycle behavior: 20+ cycles, no duplicates, successful concluding message exchange, and no persistent slowdown reported in the follow-up. Network reconnection as the cause of the earlier status delay is the user's interpretation, not instrumented evidence. Preserve the earlier timing observation. Simultaneous peer startup and CPU/memory/connection/task-growth measurements remain unverified, so full E6 and R1 are not complete. Documentation only; no code, live-device actions, staging, commit, or membership changes.

E6 simultaneous startup — October 31: following the requested procedure to quit Beakr on physical iPhone and acceptance simulator, keep Mac on XYZ, reopen both peers close together, and verify automatic reconnection and bidirectional messaging without Refresh, user reported Pass, no issues. Record user-observed PASS for this simultaneous-startup procedure. Together with the repeated-cycle observations, the exercised E6 functional checks have passed. CPU/memory and connection/task-growth trends remain unmeasured; do not infer full resource acceptance or R1 completion. Documentation only; no code, live-device actions, staging, commit, or membership changes.

### Result template

Copy this for each original A-Series case and each adverse case:

- Test ID / build / date / devices / authority state / impairment settings:
- Actions and timestamps:
- Expected result:
- Observed peer counts and recovery latency:
- Message IDs/subjects, recipients, delivery result, duplicate count:
- Failure/retry/recovery evidence from each device:
- Manual intervention used (if any):
- Verdict: PASS / FAIL / BLOCKED / NOT RUN
- Follow-up and regression reference:

Do not change NOT RUN or BLOCKED to PASS based on a related successful test.

### E8 pending-enrollment recovery — user-observed PASS, October 31

User exercised pending enrollment on XYZ with a newly created iPhone 17 Pro Max simulator. Screenshots show the Join Network review, a pending request on Mac while that simulator is shut down, and Network Joined on its root page after reopening. User then confirmed message exchange works and, in response to the no-Refresh registration question, confirmed the friendly device name now appears as Registered. Record user-observed PASS for this pending-enrollment shutdown/recovery variant, subsequent messaging, and registration-history convergence. Exact recovery latency, build identifiers, message IDs, duplicate counts, and installation execution counts were not independently captured. This does not establish interruption during installation or repeated pending-import deduplication.

The initial report of no Join button/request remains unexplained; subsequent screenshots establish a request and successful completion, not the cause of that initial observation. This run used a new membership on live XYZ, not the separate test network proposed in the prepared procedure. Preserve this membership and all existing live memberships; its creation does not authorize revocation. E2 still needs an actually unknown new member and E9 needs a specifically authorized disposable membership. No new builds/tests or assistant live-device actions; documentation only, no staging or commit.

### E2 authority-return delivery observation — October 31

Requested E2 procedure on XYZ: keep iPhone 17 Pro stopped while newly enrolling iPhone 18 Pro, quit Mac authority before reopening iPhone 17 Pro, then attempt delivery from 18 Pro to 17 Pro. User reported readiness after enrollment and confirmed the outbound message was Queued during the authority outage. Screenshot showed the observer under fallback recipient name Network Device 1540AA67 — Offline, matching its previously recorded node ID suffix. After the requested Mac restart with simulators left running and no Refresh, user reported Sent within 15–20 seconds. User then confirmed new-message delivery from iPhone 17 Pro to iPhone 18 Pro works immediately. Record user-observed successful queue recovery and return-direction messaging for this procedure. Original-message recipient-side single-copy receipt was asked about but not separately confirmed; Sent status and return messaging do not establish that count.

Full E2 trust-negative acceptance remains open: no captured membership generation, unknown-member authentication rejection, signed-refresh event, or retry telemetry establishes the outage's specific cause. Do not infer those from Offline/Queued or green peer counts. User could not find a Reply action on iPhone 17 Pro for any message; New Message worked. Preserve this as a separate unresolved UI observation, with simulator causality unproven. Both new XYZ memberships remain intact; no revocation authorization follows from this run. Documentation only; no new code, builds/tests, assistant device actions, staging, or commit.

### E9 authority removal and restart persistence — October 31

User explicitly confirmed removal of the new iPhone 18 Pro XYZ membership was performed from the Mac authority. At 20:18, screenshots showed XYZ under Preserved Contexts on iPhone 18 Pro with read-only mailboxes; iPhone 17 Pro's already-open detail page still labelled the removed device Offline. After navigating back, the 20:20 screenshot showed iPhone 18 Pro absent from iPhone 17 Pro's member list, and user explicitly confirmed No refresh. Record user-observed successful automatic member-list convergence and removed-device read-only presentation.

Following the requested restart check, user reported Looks good with a 20:22 screenshot showing the observer list still excluding iPhone 18 Pro, while the removed simulator was stopped. The subsequent 20:23 screenshot shows iPhone 18 Pro running again with XYZ still under Preserved Contexts and read-only mailboxes, and the observer list still excluding it. Record user-observed PASS for the exercised removal/convergence/restart-persistence behavior. Exact removal time, refresh latency, signed revocation generations, and authentication rejection logs were not captured. This does not prove peer-side rejection of a presented old credential; local enforcement can prevent that attempt. Full E9 trust-negative evidence and R1 signoff remain open.

Preserve UI follow-ups: an already-open removed-peer detail showed Offline rather than explaining removal; removed-device presentation has a red indicator and preserved history without a clear reason for loss of access. User described it as funky looking. Do not infer whether the old detail was stale or merely lacked removal semantics without source/runtime investigation. The user performed only the identified iPhone 18 Pro membership removal; this is not authorization to remove any other membership. Preserve its read-only history and credentials; no re-enrollment or cleanup. Documentation-only assistant work; no builds/tests, code changes, live-device actions, staging, or commits.

### E9 presentation follow-up implemented — October 31

Implemented live iOS member-detail status with verified Revoked evidence, a persistent authority-revocation explanation for newly archived local Contexts, and a visible Reply toolbar action in active-network incoming-message details. Older preserved Contexts lack the removal reason and retain generic read-only presentation. Six focused app cases passed on the isolated baseline simulator; Mac and iOS build checks passed (see handoff for exact scope). No new E9 hardware pass, peer-side old-credential rejection proof, or R1 signoff is claimed. Existing memberships/history and staging preserved.


Incoming-message navigation follow-up — October 31

User clarified that iPhone 17 Pro receives Mac messages and sends new messages, but neither single nor double clicking an incoming row opens it. This blocks reaching the new Reply toolbar; simulator causality remains unproven. Replaced the incoming row's NavigationLink plus simultaneous read-mutating tap gesture with one full-row Button selecting a message. The mailbox owns the navigation destination outside its filtered rows; marking the message read occurs when the detail opens, so an Unread-filter row disappearing cannot own/dismiss the destination. Existing context-menu/swipe actions and active-network Reply eligibility remain intact.

Xcode BuildProject passed for Beakr / iPhone 17 Pro (build only, no launch or test). Left that already-selected destination unchanged. No automated tests or interactive UI verification were run for this follow-up; user retest of single-tap opening, Reply, and Unread-filter navigation remains pending. No live device/profile/membership changes, staging, or commits. iPhone 18 Pro remains untouched.


Physical-iPhone trust-recovery blocker — November 1

User reported previously working iPhone - Dev on XYZ showing Setup Needs Attention, no Last Error, and a pulsing grey Settings icon. iPhone 17 Pro retained its message to the phone as Queued. Force-close/reopen plus 60 seconds did not recover it; Retry Device Setup also left the grey pulse unchanged. User had toggled Local Network permission the preceding day; causality is not established. Preserve this failed recovery observation separately from the successful E10 permission retest and earlier E4 failure/retest history.

Debugger identity was verified before inspection: selected iPhone 17 Pro destination originally coexisted with Mac debug PID 45595; user selected Beakr PID 10155 / 360-iPhone-Dev, then target list confirmed remote-ios. A temporary diagnostic breakpoint captured NodeBootstrapModel state identityReady, status “Network trust must be recovered before routes can start.”, XYZ selected with saved membership and message history present, and no session Last Error. The main thread was idle in its event loop. The breakpoint was deleted and the phone resumed. Attached-session OSLog retrieval returned no app entries; no successful retry or delivery is inferred. No live trust files were changed. Phone snapshot age and exact missing/stale/invalid cause were not independently measured.

Found and fixed a concrete stale-cache recovery gap in Apps/Beakr/NodeBootstrapModel.swift: DevelopmentNodeTrustBootstrapper previously returned after restoring any signature-valid revocation snapshot, while subsequent lifecycle/handshake checks require freshness within 24 hours plus clock skew. Recovery now checks the same LAN handshake freshness rules, retains the verified generation for rollback protection, fetches newer signed evidence when stale (five-second request/resource timeout), and revalidates freshness before proceeding. Fresh cached trust still supports offline startup without an authority request. Offline, unchanged, wrong-authority, rollback, or still-stale responses do not authorize networking. The helper uses existing verification and durable publication; no trust policy is relaxed.

A trustRecovery route now sets failed connectivity so it stops the startup pulse and exposes its status through Last Error, with guidance to keep the authority reachable and retry setup. Manual Refresh while not ready retries trust setup instead of starting LAN directly; startup/securing guards prevent overlapping manual setup attempts. No new SwiftUI layout or unrelated membership changes.

Validation: iOS isolated-baseline build-for-testing passed. Twelve focused app cases passed on Beakr-R1-Contract-Baseline-20261026: fresh-cache offline behavior; stale-cache recovery; five failure/rollback response variants; two lifecycle-route gating variants; bootstrapFailure; trustRecovery; foregroundRetriesFailedLANStartup. After the final manual-attempt guard, four relevant lifecycle/trust/foreground cases passed again. Final Xcode BuildProject passed for My Mac and 360-iPhone-Dev. Test bundles: Test-Beakr-2026.11.01_14-32-49--0500.xcresult and Test-Beakr-2026.11.01_14-33-29--0500.xcresult under /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/. Xcode restored to Beakr / 360-iPhone-Dev. Builds only on live targets; no updated app was installed or launched by the assistant. Existing staged/unstaged/untracked work preserved, nothing staged or committed. iPhone 18 Pro and its archived history remain untouched.

Next: user runs the updated build on 360-iPhone-Dev with Local Network enabled and Mac on XYZ, then checks reconnection and one receipt of the existing queued message. If recovery remains blocked, capture the now-visible error. Do not claim physical recovery, permission causality, incoming-message navigation acceptance, negative-trust acceptance, or R1 signoff from these automated results.


Physical-iPhone recovery retest — November 1

User ran the updated Beakr build on physical 360-iPhone-Dev and reported “Fixed immediately.” The previously queued iPhone 17 Pro message had not yet arrived because that simulator's app was not running. Following the requested startup of Beakr on iPhone 17 Pro with Mac/physical iPhone remaining on XYZ and no resend or Refresh, user confirmed the message was sent and delivered within seconds of simulator startup. Record user-observed PASS for physical-phone recovery with the fix and retained queued-message delivery after the sender returned. The reply explicitly confirms sending/delivery and qualitative timing; recipient-side single-copy count was requested but not separately confirmed.

Immediate recovery supports the stale-revocation-cache recovery defect as the likely cause; the phone's pre-fix snapshot age was not measured, and a causal connection to the preceding day's Local Network permission toggles remains unproven. Preserve the original failure, unsuccessful restart/Retry Device Setup, debugger evidence, and validation scope above. This does not establish the separate incoming-row/Reply/Unread navigation retest, full negative-trust acceptance, or R1 signoff. Documentation-only follow-up; no new builds/tests, assistant device actions, membership changes, staging, or commits. iPhone 18 Pro remains untouched.


Incoming-message navigation retest — November 1

User confirmed iPhone 17 Pro now enables opening and replying to a message with a single click. Record user-observed PASS for incoming-row opening and access to the Reply flow, resolving the previously reported inability to open incoming messages. The response does not separately establish recipient-side reply delivery or opening from the Unread filter while the row becomes read; those checks remain outstanding. No new builds/tests, code changes, assistant device actions, membership changes, staging, or commits in this follow-up. iPhone 18 Pro remains untouched; full R1 signoff remains open.


Unread navigation retest — November 1

Following the requested Mac-to-iPhone 17 Pro message, opening from the Unread filter, and replying, user reported “Yes message sent and message is read and remains open on the iPhone-17 Pro.” Record user-observed PASS for the exercised Unread navigation/read-state transition: the incoming detail remains open after marking read. User also confirmed sending the reply; recipient-side arrival on Mac was not explicitly reported in this response. Together with the preceding single-click/Reply confirmation, the reported incoming-message opening and disappearing-row navigation blocker is resolved in user acceptance. Do not infer full R1 or negative-trust signoff. Documentation only; no new builds/tests, code changes, assistant device actions, membership changes, staging, or commits. iPhone 18 Pro remains untouched.


Reply delivery confirmed — November 1

User explicitly confirmed the reply from iPhone 17 Pro arrived on Mac. The exercised incoming-message UI acceptance is now user-observed PASS: single-click opening, accessible Reply, reply delivery to Mac, and Unread-filter detail remaining open after marking read. This closes this UI follow-up only; full negative-trust acceptance and R1 signoff remain open. Documentation only; no new code, builds/tests, assistant device actions, membership changes, staging, or commits. iPhone 18 Pro remains untouched.


Isolated negative-trust evidence — November 1

Added focused package tests using disposable identities and temporary stores:
- E2 support: ProfileTrustMaintenanceTests.unknownPeerRecovery now covers authority outage/return with both eligible and revoked peers. Unknown peers remain denied during the outage; concurrent/repeated attempts coalesce and throttle refresh. After the retry deadline and authority return, signed membership admits only the eligible peer; revoked peers remain denied.
- E9 support: LANHandshakeTests.persistedRevocationRejectsOldCredential first accepts the original credential, then uses authority removal/revocation and verifies receiver-side LANHandshakeError.revokedCredential with both current and disk-reloaded signed evidence. Fresh receiver authenticators exclude replay-cache rejection as the explanation.
- E12 support: ProfileMembershipDirectoryTests.corruptPersistedMembershipFailsClosed and RevocationRefreshTests.corruptPersistedRevocationsFailClosed cover malformed and wrong-authority persisted evidence. Opening/restoring fails, revocations are not published, and the original file bytes remain intact.

Validation: Xcode BuildProject(buildForTesting: true) passed for BeakrNet-Package / My Mac. That scheme exposed zero runnable tests, so focused package tests ran through SwiftPM with --disable-sandbox after its nested sandbox was denied; the outer workspace sandbox remained in place. All 40 test functions across seven suites passed (12 Host tests and 28 Core tests; parameterized cases included), exit 0. Suites: ProfileTrustMaintenanceTests, ProfileMembershipDirectoryTests, ProfileMembershipRefreshTests, LANHandshakeTests, RevocationRefreshTests, RevocationDistributionTests, CredentialRevocationTests. Log: /private/tmp/Beakr-R1-Negative-Trust-20261101.log. These results apply to this package-test change; no app tests or live-device rerun occurred in this step.

Scope: outage recovery uses an injected certificate/public-key connection adapter, and handshake tests use synthetic certificate bytes with real identity signatures. This establishes isolated resolver/handshake and persisted-trust behavior, not real TLS transport, physical-radio failure, payload delivery, or a captured old-credential attempt from the live removed iPhone 18 Pro. Full E2/E9 hardware negative-trust evidence and R1 signoff remain open. Earlier E4 failure and successful retest remain recorded.

User reports iPhone 18 Pro remains running, untouched since removal, with red Settings and no active XYZ network. Preserve its archived history; do not reset, clean up, or re-enroll it. No production code changed in this step. Xcode restored to Beakr / 360-iPhone-Dev; no live app launched, membership changed, files staged, or commit created.


Reply marks unread original read after queue admission — November 1

Before E6 cycling, user confirmed bidirectional delivery and Reply between physical iPhone-Dev and iPhone 17 Pro. User then observed that replying without opening the incoming message left it unread. E6 cycling/resource measurement has not started; this exchange establishes only the functional starting point.

Fixed MessageComposerModel to retain the original IncomingMessage when preparing a reply. After successful host queue admission, a reply addressed to that original sender marks the original read using the existing read/receipt path. It does not wait for delivery. Merely preparing or cancelling composition, failed admission, forwarding/resending, or sending to a different recipient does not mark the original read. Mac and iOS Reply entry points now supply the message; composer dismissal clears the association. Mailbox attachment clears it and advances a generation guard so completion of an in-flight send/read receipt cannot mutate another mailbox's state.

Validation: Xcode baseline build-for-testing passed; 12 focused app cases passed exclusively on Beakr-R1-Contract-Baseline-20261026 (eight replyReadOnAdmission scenarios plus queueMessage, sendOnlineMessage, hostFailure, readReceipt). Checks include persisted read state and receipt deduplication. Test bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_14-58-00--0500.xcresult. Mac and 360-iPhone-Dev BuildProject passed. No live app installed/launched by the assistant, no membership/profile changes, nothing staged or committed. Xcode left on Beakr / 360-iPhone-Dev; iPhone 18 Pro untouched.

Next: user Run on physical iPhone-Dev, receive a fresh message from iPhone 17 Pro, use the unread row's context-menu Reply without opening the detail, and Send. Confirm the original becomes read and the reply arrives. A separate cancelled reply should leave a fresh original unread. Visual acceptance remains pending; existing E4 failure/retest and open R1 acceptance items remain unchanged.


Reply/read visual retest and E6 foreground cycling — November 1

User confirmed “Yes fixed” after the requested physical-iPhone-Dev unread-row context-menu Reply/Send retest. Record user-observed PASS for marking the replied-to original read. The cancelled-composer visual variant was not separately reported; automated coverage remains as recorded above.

User then explicitly confirmed completing 10 + 10 Home Screen/foreground cycles on physical iPhone-Dev and that all messages were delivered and replied to with iPhone 17 Pro. Record user-observed PASS for the exercised 20-cycle messaging/reply behavior. Instructions specified approximately two seconds on Home Screen, no force-close or Refresh, and settling before screenshots; exact timing and lack of manual intervention were not separately restated. Single-copy counts were requested but not explicitly confirmed by the final response.

Xcode screenshots identify the same physical-device Beakr PID 10237 throughout:
- 15:00:39 baseline: CPU 0%, memory 50.7 MB, Energy Impact High.
- 15:03:44 after first 10 cycles: CPU 0%, memory 56.1 MB, Energy Impact High.
- 15:06:35 after second 10 cycles: CPU 0%, memory 53.9 MB, Energy Impact High.
The Mac process PID 45595 separately shows 100.3 MB and CPU 0% in all three screenshots; do not mix these with phone readings. Phone memory decreased 2.2 MB from midpoint and ended 3.2 MB above baseline. These three samples show no monotonic growth, but do not establish absence of leaks, bounded task/connection counts, or resolved energy use. CPU values are instantaneous. No simultaneous-two-peer-start variant or instrumented resource trace was performed. Full E6 resource/energy acceptance and R1 signoff remain open.

Next bounded observation: leave physical iPhone-Dev foreground and idle for two minutes with Mac and iPhone 17 Pro unchanged, then inspect CPU, memory, and Energy Impact again. Persistent High energy requires examining the energy detail/timeline before attributing a cause. No further cycling is needed for this observation. Preserve iPhone 18 Pro and its archived history unchanged.

Documentation only in this follow-up; no code changes, builds/tests, live-device actions by the assistant, staging, or commits. Prior E4 failure and successful retest remain preserved.


E6 idle settling observation — November 1, 15:10:04

Following the requested two-minute foreground idle observation, the user's screenshot shows physical iPhone-Dev Beakr PID 10237 at CPU 0%, memory 54 MB, Energy Impact Low, and instantaneous disk/network Zero KB/s. Memory is 0.1 MB above the preceding 53.9 MB reading and 3.3 MB above the original 50.7 MB baseline. The earlier High phone energy indication settled to Low; do not retain it as a persistent idle-phone failure or infer its cause. Combined with the user-confirmed 20 cycles and successful delivery/replies, this supports the exercised foreground-cycle behavior and short-run resource settling. It is not a leak analysis, a task/connection-count trace, or full E6/R1 signoff.

The separate Mac Beakr PID 45595 shows CPU 0%, memory 100.4 MB, Energy Impact High, and network 1 KB/s in this screenshot. This is distinct from the phone's Low reading; no causal conclusion or Mac energy pass follows from the phone observation. No more phone cycles requested. Documentation only; no code/build/test/device/membership changes, staging, or commits. iPhone 18 Pro remains untouched.


Mac idle-energy source review — November 1

The 15:11:16 Mac PID 45595 Energy report showed High, CPU 0%, memory 100.5 MB, one wake in the last second and displayed average zero wakes/sec, with repeated utilization/wake bars. Clicking the timeline did not expose further detail; the assistant's instruction to select a bar was unhelpful and was withdrawn. No profiler was started.

Read-only source review found recurring runtime work: ApplicationLANRuntimeManager checks the durable outgoing queue every two seconds even when empty, and publishes local network information to connected peers every five seconds in addition to path-change updates. ProfileConnectionRegistry.publishNetworkInfo sends to each peer without suppressing identical reports. ContentView performs local member/enrollment reconciliation every 15 seconds. Signed membership/revocation refresh defaults to 15 minutes, with retry deadlines on failure. Runtime stop cancels the three owned runtime tasks. These are candidates for periodic idle activity, not proof of the observed Mac energy rating or a leaked loop. Both phone and Mac use the runtime loops; the phone's settled Low reading prevents attributing the Mac difference solely to their existence. Source review does not establish what the already-running Mac binary actually executed.

No production changes, builds, tests, profiler/debugger actions, live membership changes, staging or commits in this review. Mac energy attribution remains open; avoid changing delivery/trust cadence solely to lower a gauge. The next diagnostic step is a short process-specific energy/wakeup recording for Mac Beakr PID 45595, preserving the authority and live devices. iPhone 18 Pro remains untouched.


Mac process sampling — November 1, 15:16

Verified PID 45595 through its full executable path as the macOS Debug/Beakr.app/Contents/MacOS/Beakr process. Workspace sandbox blocked ps and Instruments kernel queries; approved commands outside that sandbox were used. xctrace Power Profiler attachment failed explicitly because that instrument does not support macOS (requires iOS/iPadOS). The saved /private/tmp/Beakr-Mac-Idle-20261101-1515.trace is a failed recording, not usable energy evidence.

Fallback /usr/bin/sample captured PID 45595 for ten seconds at a requested 1 ms interval. Successful report: /private/tmp/Beakr-Mac-Idle-20261101.sample.txt, timestamp 15:16:48. Report identifies macOS, parent debugserver, launch October 31 20:10:59 -0400; this is the continuing older process, not a newly launched build. Physical footprint 100.6 MB, peak 122.3 MB. Main thread has 8191 of 8235 sampled stacks in its event-loop Mach wait; worker stacks are overwhelmingly parked in __workq_kernreturn. Brief work includes member reconciliation/credential verification and SwiftUI/AppKit layout. No sustained busy loop appears in this sample. Stack proportions are not a CPU-utilization or energy measurement, and cannot exclude brief costly wakes or establish the cause of High Energy Impact.

No code changes justified by this evidence alone. Mac energy attribution remains open; full E6 and R1 signoff are not claimed. No app was intentionally stopped, relaunched or debugger-paused, no device/profile/membership modified, no build/test run, and nothing staged or committed. iPhone 18 Pro remains untouched.


E11 network inventory — November 1

User clarified all Apple products use the 360-Starlink LAN; Mac Wi-Fi has been off for weeks and Mac is Ethernet-only. Spare Linksys WRT1900ACS uses original firmware and broadcasts 360-Rogers; a third experimental router is not selected for this work. Read-only inventory confirms Ethernet en0 active at 192.168.1.157/24, IPv4 default gateway 192.168.1.1, Wi-Fi en1 powered Off/inactive. Service order: Ethernet, Thunderbolt Bridge, Wi-Fi, iPhone USB. Other listed Ethernet adapters have inactive links; their availability as physical spare connections is not established. IPv6 has an Ethernet default and scoped tunnel defaults; no changes made. Initial networksetup inventory was sandbox-blocked, then succeeded with approved read-only elevated execution.

No verified route to the spare LAN exists yet. Obtain the Linksys LAN/router address and subnet before considering a second connection; overlapping 192.168.1.0/24 LANs would make a simple dual connection unsuitable. Ethernet service priority alone does not prove a second connection will preserve discovery, routes, or authority reachability. A second physical LAN also does not supply measured packet loss/latency or independent Beakr authority hosting. Only the selected active Beakr network currently hosts its authority; switching the live Mac to a test Beakr network would interrupt XYZ authority. E11 topology/impairment mechanism remain unprepared; no E11 run or pass claimed. No interface, route, router, profile, membership, live app, or device changes; no builds/tests, staging or commits. iPhone 18 Pro untouched.


E11 tooling review and corrected spare-network inventory — November 1

User's ThinkPad connected to 360-Rogers at 10.0.0.106 with gateway 10.0.0.1. Router UI screenshot identifies ARRIS TG4482A, hardware revision 10, not the previously assumed Linksys WRT1900ACS. Subnet mask remains unreported. User also supplied a Morse Micro HaLowLink 2 label with default IP 192.168.12.1; its current settings are unverified. No router credentials are reproduced here. No further hardware configuration is needed for the next isolated protocol-test step.

Read-only repository review found:
- BeakrNetAuthorityServer is an existing separate macOS executable. It accepts explicit authority key/ledger/network ID/port, binds 127.0.0.1 by default, and exposes LAN only with --lan. AuthorityHTTPSServerIntegrationTests generates disposable credentials/storage, starts that server on a high port, exercises real TLS enrollment/membership/revocation, and cleans up its own process. This can coexist with XYZ without adding independent authority hosting to the product app. The earlier single-active-network limitation applies to the Beakr app, not this test executable. Windows hosting is not provided by this executable (Darwin/Network/Security dependencies).
- InMemoryTransport provides immediate envelope delivery and close/error behavior, not configurable delay/loss. BeakrNetHandoffLab and DataHandoffTests exercise synthetic ambiguous LAN writes and relay fallback. Their relay scenario must not be presented as implemented R1 product routing.
- PersistentHostMessagingServiceTests checks durable queue identity through restart/retry; SessionDeliveryDriverTests covers ambiguous sends/pending delivery; ProfileTrustMaintenanceTests covers outage recovery. No turnkey E11 controlled packet-loss/latency harness was found in the inspected tools.
- SignedLANIntegrationTests covers real mTLS transfer, trust rejection and installation. Its shell wrapper invokes xcodebuild and temporarily edits a test plan; do not run it under the present BuildProject-only and preservation constraints. App tests remain restricted to Beakr-R1-Contract-Baseline-20261026.

Concrete next implementation: add a test-only scripted delivery fixture around existing persistent messaging/session tests, using disposable IDs/storage and explicit per-attempt delays/failures. Start with baseline, a recorded 250 ms delivery delay, failure before receiver acceptance, and failure after receiver acceptance but before acknowledgement; verify unchanged envelope identity across retries, one receiver acceptance, durable pending state until acknowledgement, and bounded attempt counts. Keep LAN-only semantics; do not introduce relay fallback or loosen trust. Existing authority-outage fixtures can support intermittent-authority coverage independently; combining them into a real TLS loopback run requires a further harness extension. These are application-message failures/delays, not measured raw IP packet loss. Actual E11 packet loss, UI responsiveness and physical-network behavior remain unproven until a separately scoped integration/device run.

This review prepared the test approach only: no new harness implemented or executed, no builds/tests or live listeners launched, no network/device/profile changes, staging or commits. XYZ and iPhone 18 Pro remain untouched. Full E11 and R1 signoff remain open.


E11 isolated delivery fixture implemented — November 1

Added Packages/BeakrNet/Tests/BeakrNetHostTests/ImpairedDeliveryTests.swift, with five parameterized scenarios: baseline, 250 ms delay, disconnect before receiver acceptance, disconnect after receiver acceptance before acknowledgement, and a lost acknowledgement with the route retained. The fixture composes PersistentHostMessagingService, disk-backed PersistentDataState, SessionDeliveryDriver, PeerRouteCoordinator and a receiving BeakrNetSession. Only local routes are registered; there is no relay fallback. IDs and stores are disposable. Authentication is an explicit fixture precondition, not a real TLS exchange.

Assertions establish one session-level receiver acceptance, duplicate rejection after lost/ambiguous acknowledgement, full-envelope equality across disk reload/retry with a fixed exactly representable timestamp, preserved correlation ID, one transport attempt initially and two only for recovery scenarios, no further transport attempts during three explicit retry ticks without a route, rejection of stale-generation acknowledgements, and persistence of pending state until a valid acknowledgement is accepted. Final disk reopen shows an empty queue; an additional retry issues no send. The test itself bridges accepted session acknowledgements to durable-store removal: production app acknowledgement wiring and automatic timer cadence are not exercised. Receiver-process restart, application-level mutation counts, UI responsiveness, physical radio, and raw IP packet loss are not proven.

Validation: final BeakrNet-Package / My Mac Xcode BuildProject(buildForTesting: true) passed. The package scheme previously exposed no runnable tests, so focused SwiftPM package tests ran with --disable-sandbox under the outer workspace sandbox. Final exit 0: 16 test functions across five suites (ImpairedDeliveryTests, PersistentHostMessagingServiceTests, ProfileTrustMaintenanceTests, DataHandoffTests, SessionDeliveryDriverTests), including all five new scenarios and existing parameterized authority-outage checks. The delay scenario recorded 0.256819167 seconds for initial submission with a configured 250 ms delay. No real authority server/listener was launched in this step. Log: /private/tmp/Beakr-E11-Isolated-20261101-retest.log.

Initial run failed strict envelope-equality expectations after JSON persistence with Date() timestamps; replacing the fixture timestamp with an exactly representable fixed value resolved those expectations. Persistence uses millisecondsSince1970; monotonic delay measurement remains independent. Initial log retained at /private/tmp/Beakr-E11-Isolated-20261101.log. No production persistence behavior was changed or general arbitrary-date round-trip guarantee established.

These are supporting isolated E11 protocol results, not full E11 acceptance. Controlled real-network impairment and UI evidence remain open, as does R1 signoff. No router changes, live-device runs, membership/profile mutations, or app tests. Xcode restored to Beakr / 360-iPhone-Dev. Existing staged/unstaged/untracked work preserved; the assistant issued no staging or commit commands. iPhone 18 Pro remains untouched. git diff --check passed.


E11 real TLS loopback impairment — November 1

Extended the opt-in AuthorityHTTPSServerIntegrationTests.realTLSControlPlane fixture. It creates its own authority/CA/leaf identity, network ID, ledger and temporary files, starts the real BeakrNetAuthorityServer on loopback, and performs existing enrollment/membership/revocation checks. A test-only Python TCP proxy then binds 127.0.0.1 on an OS-selected port and forwards encrypted bytes without terminating TLS. curl still validates the disposable authority certificate and hostname. No system packet filter, router change, LAN listener, or production identity is used.

Proxy sequence: baseline membership retrieval; 250 ms hold on the first client bytes; one connection cut on the first server TLS bytes; recovery membership request; recovery revocation request. The interruption occurs during TLS establishment, not after application-message acceptance. The client throws on the interrupted connection. The recovered snapshots equal baseline and pass signature/credential verification. Assertions count exactly five proxy connections (three baseline-mode, one delayed, one interrupted) and one cut. Recovery is an explicit subsequent request by the fixture, not proof of app automatic retry cadence. The separate prior envelope-failure tests provide supporting duplicate/queue evidence; do not combine the two into an unperformed end-to-end test.

Validation: Xcode BuildProject passed for BeakrNetAuthorityServer / My Mac and final BeakrNet-Package build-for-testing. Initial Swift compilation exposed a nested #require macro error; fixed by extracting port and URL checks. The sandboxed opt-in run then failed in disposable authority TLS setup before listening (LANTLSConfigurationError). Approved host-context rerun passed, exit 0: one integration test, no skips, duration 2.029 seconds. Configured delay 250 ms, measured request elapsed 0.336333084 seconds. Successful log: /private/tmp/Beakr-E11-TLS-20261101-host.log. Prior compile/sandbox logs retained at /private/tmp/Beakr-E11-TLS-20261101.log and /private/tmp/Beakr-E11-TLS-20261101-retest.log. The exact underlying OSStatus of the sandbox TLS error was not captured.

The test's defer cleanup terminates only its own proxy and authority subprocesses and removes its temporary credentials/storage. No live Beakr process stopped or relaunched, no app tests or live profile/membership changes, no staging/commit commands. Xcode restored to Beakr / 360-iPhone-Dev. iPhone 18 Pro remains untouched. Documentation and test infrastructure only; no product code changed. git diff --check passed.

This establishes real loopback TLS delay/failure/re-request recovery for the authority control plane. It does not establish raw IP packet-loss behavior, interrupted message-body/acknowledgement recovery over real TLS, UI responsiveness, physical-network recovery, or full E11/R1 signoff.


E11 real TLS message/acknowledgement recovery — November 1

Added AppleNetworkIntegrationTests.lostAcknowledgementOnLoopback and a loopback-only mode in its existing fixture. The listener binds 127.0.0.1 on an OS-assigned port without advertising Bonjour; the browser is not started. BeakrNetAppleIntegrationTests now explicitly depends on BeakrNetData for disposable disk-backed outgoing state.

The test establishes a real encrypted connection and Beakr signed handshake, sends a durable envelope, observes SessionDeliveryDriver receiver acceptance, then cancels the server connection before writing the acknowledgement. The client observes stream end while sender session and reopened disk store retain the pending envelope. After explicit fixture reconnection/authentication and route replacement, the identical disk-loaded envelope is sent again. Receiver session rejects it as a duplicate and produces an acknowledgement, which travels back over the new TLS connection as a Control envelope. An old-route acknowledgement is rejected; the current-route acknowledgement clears the sender session. The fixture then bridges the accepted acknowledgement to disk-store removal and verifies the reopened store is empty. Diagnostic history shows one acceptance and one duplicate; attempt count is exactly two.

Scope: real Network.framework TLS 1.2 using the existing test PSK configuration, plus Beakr's signed handshake with synthetic certificate metadata injected through the existing adapter seam. This is not production certificate-authenticated TLS 1.3. Receiver/session state stays alive across reconnection. The test drives reconnect/retry and durable-store acknowledgement explicitly; it does not exercise automatic product lifecycle, app acknowledgement wiring, UI, receiver-process restart, raw packet loss, or physical radio. One protocol acceptance is established, not a rendered inbox count or application mutation count. Only local routes are used; no relay service or fallback.

Validation: Xcode BeakrNet-Package / My Mac build-for-testing passed. The focused opt-in package integration test passed with no skips under the workspace sandbox using swift test --disable-sandbox; final exit 0, one test, 0.017 seconds. Log: /private/tmp/Beakr-E11-MessageTLS-20261101-final.log. Earlier fixture compile errors were corrected (route-removal reason and argument ordering). A subsequent invalidDeliveryPolicy failure came from the acknowledgement's default queued policy without an expiry; it now uses the production ephemeral Control policy. The data fixture also specifies a durable 60-second expiry. Initial diagnosis attributing the rejection to missing durable expiry was corrected; product code was not changed.

No live Beakr launch/stop, app tests, device/profile/membership changes, network configuration, staging or commit commands. Temporary fixture connections/listener and storage are cleaned up. Xcode restored to Beakr / 360-iPhone-Dev. iPhone 18 Pro remains untouched. Full E11 and R1 signoff remain open; these are additional isolated protocol results. git diff --check passed.


E11 production delivery-component recovery tests — November 1

Extracted the existing ApplicationLANRuntimeManager acknowledgement-to-disk/delivery-update operation and two-second retry loop into ApplicationDeliveryPipeline in the same source file. The live runtime calls these helpers; cadence, cancellation/error handling and acknowledgement semantics are unchanged. This is a production-code refactor to share the exact operations with tests, not a new recovery policy.

Added BeakrTests.automaticDeliveryRecovery(lostAcknowledgement:) with two isolated scenarios: unavailable route at initial send followed by route availability, and first acknowledgement discarded by an injected transport. Tests compose real PersistentHostMessagingService, AuthenticatedTransportRouteOwner receive/ack generation loops, session drivers/coordinators, ApplicationMessageInbox with disk storage, ApplicationDeliveryUpdates, MessageComposerModel and the extracted production retry/ack operations. Only transport and route availability are controlled by the fixture. The test never invokes retryPending or acknowledgement clearing directly. It starts the production two-second loop, waits up to eight seconds for Delivered, verifies a cleared durable sender queue after disk reopen, one incoming stored result and correct inbox event/correlation/body, identical envelopes on retry, expected one or two transport sends, one receiver acceptance, and one duplicate only in the dropped-ack variant. An extra 2.1-second interval confirms no further sends or inbox records after acknowledgement.

Validation: iOS baseline BuildProject(buildForTesting: true) passed. Six focused app cases passed only on Beakr-R1-Contract-Baseline-20261026: two automaticDeliveryRecovery variants, queueMessage, sendOnlineMessage, hostFailure, readReceipt; zero failures/skips. Bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_16-00-11--0500.xcresult. Final Mac and 360-iPhone-Dev BuildProject passed. git diff --check passed.

Scope: these are app-hosted production-component tests with in-memory transport; authentication is a precondition and route availability restoration is fixture-driven. They do not start the full ApplicationLANRuntimeManager, discover/reconnect sockets, exercise ProfileConnectionRegistry admission, inspect rendered UI, or combine the earlier real TLS impairment fixture with the app runtime. Delivered model state and one persisted inbox record are proven; production end-to-end network/UI recovery and raw packet-loss E11 acceptance remain open. No live app installed/launched by the assistant, router/settings/profile/membership changes, staging or commits. Xcode restored to Beakr / 360-iPhone-Dev. iPhone 18 Pro untouched; full R1 signoff remains open.


E11-UI-1 visual queue recovery — November 1

Following the requested normal app shutdown on iPhone 17 Pro while Mac authority remained running on XYZ, user sent E11-UI-1 from physical iPhone-Dev. User reported arrival immediately upon starting iPhone 17 Pro. In response to the explicit checklist (one received copy, left sender Outbox and appeared in Sent Items, responsive UI while queued, no Refresh/resend), user confirmed “no refreshes and all behave as requested... including the Sent, but un-opened status display from the Sender's perspective”. Record user-observed PASS for this exercised visual queue-recovery check: single-copy receipt, sender mailbox transition, responsive UI, no manual Refresh/resend, and Sent/unopened presentation before recipient opening. Recovery timing is qualitative; no measured latency or receipt identifiers were captured.

This is an app-offline/return observation, not controlled delay or packet-loss injection. Together with isolated protocol/TLS/component tests it adds supporting E11 evidence but does not complete full E11 or R1 signoff. No additional device actions needed for this check. iPhone 18 Pro remains untouched. Documentation-only follow-up; no code changes, builds/tests, assistant live-device actions, profile/membership modifications, staging or commits. Prior E4 failure and successful retest remain preserved.


E13 isolated creation checks — November 1

Reviewed existing coverage and ran six existing app test cases on Beakr-R1-Contract-Baseline-20261026: createNetwork, three createAdditionalNetwork(failureStage:) variants (success, creator failure, enrollment preparation failure), normalCreationRecordsInstallation, and emptyRegistryCreatesNoNetworkSessions. All six passed with zero failures/skips after Xcode BuildProject(buildForTesting: true) passed. No additional test or product-code changes were needed for these checks.

The additional-network fixture asserts that creation and both injected failures preserve the original selected/active profile, authority and LAN start/stop counts, authenticated peer list, ready state and connected presentation. Failed setup leaves only the original profile, no new configuration and no last-created ID. Success leaves the new profile inactive until explicit switching. First-network creation exercises automatic activation through NodeBootstrapModel with injected creator/runtime/trust dependencies; the separate installation test checks the persisted createNetwork lifecycle transaction. Empty-registry startup creates no sessions.

Scope: these are model/component fixtures, not a clean-install Mac UI run, real authority creation failure, or live messaging during failure. Earlier hardware normal creation/activation/return PASS remains valid; creation-failure and clean-install first-network hardware variants and full R1 signoff remain open. Result bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_16-14-34--0500.xcresult.

Xcode restored to Beakr / 360-iPhone-Dev without launching the live app. No live device, router, profile or membership changes; iPhone 18 Pro untouched. No staging or commit commands. Documentation-only updates; git diff --check passed.


Cancelled reply preserves unread state — November 1

User confirmed the requested Reply-Cancel-1 visual check: a fresh message from iPhone 17 Pro to physical iPhone-Dev was replied to through the unread row's context menu without opening the original; after typing, cancelling and discarding the draft, the original retained its unread indicator and no reply arrived on iPhone 17 Pro. Record user-observed PASS for cancelled-reply unread-state preservation. Together with the earlier successful-send retest, this closes the exercised reply/read-state UI follow-up. Full R1 signoff remains open.

Documentation-only update. No builds/tests, live-device actions, profile/membership changes, staging or commits by the assistant. iPhone 18 Pro remains untouched.


Negative-trust admission over loopback TLS — November 1

Extended AppleNetworkIntegrationTests with rejectsInvalidCredentialOnLoopback, parameterized for expired, revoked and wrong-authority client credentials. Each case creates disposable identities, establishes a real Network.framework loopback TLS connection without Bonjour advertising, and runs production LANTransport.authenticate on both ends. The test client attempts an application frame immediately after sending its signed handshake proof. The receiver must fail with exactly expiredCredential, revokedCredential or invalidCredential, emit the matching authenticationFailed diagnostic, read only the hello/proof frames, and never return an admitted transport. A five-second watchdog closes fixture connections on a stall; it is not accepted as credential rejection. Payload transmission is attempted, but a receiver closing promptly can reject the write before its bytes arrive; the test does not assert delivery of the malicious payload to the socket.

All three negative cases passed. The existing valid-credential lostAcknowledgementOnLoopback test also passed, exercising successful admission, message acceptance, duplicate rejection after reconnect and durable acknowledgement clearing with the modified fixture. Swift Testing reports two test functions, including three parameterized negative cases, zero failures, total 0.028 seconds. Xcode BeakrNet-Package / My Mac BuildProject(buildForTesting: true) passed. Focused package tests ran via swift test --disable-sandbox under the workspace sandbox, using BEAKRNET_RUN_APPLE_NETWORK_INTEGRATION=1. Log: /private/tmp/Beakr-Negative-TLS-20261101.log.

Scope: real loopback TLS 1.2 using the existing test pre-shared key configuration; certificate bytes/public-key metadata are injected by TestCertificateConnection. Beakr credential and proof verification are real. This proves receiver-side Beakr admission rejection over an encrypted connection, not production certificate-authenticated TLS 1.3 validation, rendered inbox behavior, full ApplicationLANRuntimeManager assembly, physical-radio behavior, or an old-credential attempt from removed iPhone 18 Pro. Full hardware negative-trust acceptance and R1 signoff remain open.

Test infrastructure and documentation only; no product code changes. Fixture listeners/connections are cancelled. Xcode restored to Beakr / 360-iPhone-Dev. No live app launched/stopped, live membership/profile/router changes, staging or commits. iPhone 18 Pro remains untouched. git diff --check passed; prior E4 failure and successful retest retained.


Production LAN TLS certificate admission — November 1

Added opt-in ProductionLANTLSIntegrationTests.certificateAdmission using production LANTLSConfiguration.parameters with .production(authorityCertificates:) on both endpoints. This configuration requires mutual certificate authentication and pins TLS 1.3; no PSK, developmentSelfSigned policy or injected peer-certificate metadata is used. Disposable OpenSSL-generated CAs and leaf identities are imported with SecPKCS12Import/kSecImportToMemoryOnly, without adding them to the user's persistent keychain. Listeners bind only 127.0.0.1 on OS-assigned ports, without Bonjour advertisement. Temporary certificate/key files are removed and fixture listeners/connections cancelled.

Seven connections exercised: a foreign-CA identity works with its own trusted CA; the designated trusted identity works before the negative checks; an untrusted client, untrusted server, expired client and expired server each fail at the verifying endpoint without that endpoint reaching ready; the trusted identity works again afterward. Positive controls require both endpoints ready and receipt of a fixed raw application-data marker. Security.framework independently verifies the expired fixture's failure code is errSecCertificateExpired. Network.framework reports generic TLS -9808 for the rejected connections. The fixture accepts a TLS error in failed or waiting state, never a timeout or non-TLS error; it cancels the connection immediately after evidence is collected. This does not measure long-term automatic retry behavior.

Validation: Xcode BeakrNet-Package / My Mac BuildProject(buildForTesting: true) passed. Focused package test ran under the workspace sandbox with BEAKRNET_RUN_PRODUCTION_TLS_INTEGRATION=1 swift test --disable-sandbox --filter ProductionLANTLSIntegrationTests. One test function covering seven connections passed in 0.316 seconds, exit 0, no skips. Log: /private/tmp/Beakr-Production-TLS-20261101.log. Initial fixture failures were corrected: OpenSSL rejected negative validity days, replaced with explicit historical notBefore/notAfter dates; the original state observer missed TLS errors reported as waiting, now handled explicitly. No production TLS policy was changed.

Scope: this establishes isolated production TLS certificate-chain/expiry admission behavior in both roles, using real Security.framework verification and Network.framework sockets. It does not run Beakr's signed credential handshake, full app runtime, inbox persistence, hardware transport, keychain enrollment/renewal flow or application revocation over this TLS fixture. Prior Beakr-credential negative tests remain separate supporting evidence. TLS-level certificate revocation was not tested. Full hardware negative-trust acceptance and R1 signoff remain open.

Test infrastructure/documentation only. Xcode restored to Beakr / 360-iPhone-Dev without live app launch/stop. No live device/profile/membership/router changes, staging or commits; iPhone 18 Pro untouched. git diff --check passed; historical E4 failure and post-fix pass preserved.


Combined production mutual TLS and Beakr credential admission — November 1

Added ProductionLANTLSIntegrationTests.combinedCredentialAdmission. Disposable P-256 NodeIdentity keys are used for CA-signed TLS leaf identities and Beakr signed credentials, with PKCS#12 imported into process memory only. The existing production TLS loopback fixture now optionally hands its two ready sockets to the protocol check. Production NetworkBonjourConnection reads the actual peer certificate and public key from TLS metadata; the test checks these match the client identity. There is no injected certificate metadata, PSK, or developmentSelfSigned trust policy.

First connection: both TLS endpoints reach ready, production LANTransport authenticates signed Beakr credentials/proofs, and two copies of the same envelope travel over the connection. SessionDeliveryDriver accepts the first and rejects the second as duplicate. Session diagnostic history contains exactly one envelopeAccepted and one duplicateRejected event. Second connection uses the same still-valid TLS identities and original Beakr credentials, but installs a fresh signed fixture snapshot revoking the client credential. Both TLS endpoints again reach ready; receiver-side LANTransport.authenticate throws exactly revokedCredential and never supplies a transport for delivery. The sender attempts a send if its authentication returns successfully; rejection may close the socket first. Receiver acceptance/duplicate counts remain unchanged. A five-second connection-cancelling watchdog bounds protocol operations and cannot pass as the expected revocation error.

Validation: Xcode BeakrNet-Package / My Mac BuildProject(buildForTesting: true) passed. With BEAKRNET_RUN_PRODUCTION_TLS_INTEGRATION=1, swift test --disable-sandbox --filter ProductionLANTLSIntegrationTests passed both test functions in 0.423 seconds (combined case 0.150 seconds), exit 0, no skips. This reruns the earlier seven certificate-validation connections plus the two combined connections. Log: /private/tmp/Beakr-Combined-TLS-20261101.log. Initial test compile errors (missing BeakrNetAuthority import and optional Task result inference) were corrected before execution. No product code changed.

Scope: combined production TLS 1.3 configuration, real peer-certificate extraction, Beakr signed handshake, LAN framing and session-level acceptance/deduplication are exercised. Revocation evidence is generated and supplied directly by the fixture, not fetched by the live authority-refresh pipeline. One protocol acceptance is established, not a rendered or persisted app inbox, application side-effect count, durable sender acknowledgement, full ApplicationLANRuntimeManager assembly or hardware negative-trust run. Full R1 signoff remains open.

Test infrastructure/documentation only. Fixture connections/listeners are cancelled and disposable key/certificate files removed; no persistent keychain import. Xcode restored to Beakr / 360-iPhone-Dev. No live app launch/stop, device/profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched; prior E4 failure/retest retained. git diff --check passed.


Combined TLS/Beakr persistent incoming-store verification — November 1

Extended ProductionLANTLSIntegrationTests.combinedCredentialAdmission to persist an accepted canonical DataMessage through the production PersistentDataState storage primitive. The fixture bridges SessionDeliveryDriver's accepted result to StoredDataResult, mirroring the storage boundary without importing ApplicationMessageInbox. The valid duplicate is rejected at session level before persistence. The revoked connection attempts a distinct envelope/message ID, correlation ID, idempotency key and body, so storage deduplication cannot hide unauthorized acceptance.

After each connection, both the live store and a newly opened PersistentDataState instance must contain exactly the expected original StoredDataResult, including message ID, correlation/idempotency metadata, body and completion timestamp. The revoked envelope must have no stored result. The incoming file must remain byte-for-byte unchanged after the revoked attempt and reopening. All checks passed; valid acceptance and duplicate diagnostic counts remain one each, and revoked authentication still fails specifically with revokedCredential after successful production mutual TLS.

Validation: Xcode BeakrNet-Package / My Mac BuildProject(buildForTesting: true) passed. Focused package tests via BEAKRNET_RUN_PRODUCTION_TLS_INTEGRATION=1 swift test --disable-sandbox --filter ProductionLANTLSIntegrationTests passed both functions in 0.414 seconds, no skips/failures, exit 0; combined persistence case 0.131 seconds. Log: /private/tmp/Beakr-Combined-Persistence-20261101.log. git diff --check passed.

Scope: actual production incoming storage and disk reopening are exercised with a test-owned acceptance-to-storage bridge. This is not ApplicationMessageInbox integration, rendered UI, a full process restart, receiver-session deduplication across restart, or the full app/network runtime. Revocation evidence remains supplied by the fixture. Full hardware acceptance and R1 signoff remain open. No product code changes.

Test/documentation updates only. Xcode restored to Beakr / 360-iPhone-Dev. No live app/device/profile/membership/router changes, staging or commits; iPhone 18 Pro untouched. Temporary fixture storage/credentials/connections are cleaned up; prior E4 failure/retest retained.


Application inbox recreation and retried-envelope suppression — November 1

Added BeakrTests.inboxRestartSuppressesRetry using the actual ApplicationMessageInbox and disposable PersistentDataState. The first inbox records a canonical text message, emits one non-restored update with expected source/body, and saves one result. The test then creates a new store instance and inbox, subscribes before attaching the reopened store, and retries the original envelope twice. Stored message ID/content remain correct, result count remains one, and the file is byte-for-byte unchanged. A further independently opened store confirms the same single original message.

A distinct valid follow-up message provides a deterministic observer barrier. The recreated inbox's update stream contains exactly the restored original (isRestored=true, correct source/body/storage ID/profile provenance) followed by the new barrier message (isRestored=false). No new-message update for either original retry occurs. Storage then contains two results intentionally, because the barrier is a second legitimate message. A five-second timeout bounds observer reads; no sleep-based absence assertion is used.

Validation: Xcode Beakr / Beakr-R1-Contract-Baseline-20261026 BuildProject(buildForTesting: true) passed. Three focused app cases passed on that isolated baseline only: inboxRestartSuppressesRetry, inboxMetadata, readReceipt; zero failures/skips. Bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_16-54-26--0500.xcresult. git diff --check passed.

Scope: actual app inbox object recreation, disk reopening, persisted known-message restoration and retry notification suppression are proven. This is not app process termination/relaunch, rendered UI or OS notification behavior, concurrent duplicate delivery, or a combined TLS-to-app runtime test. Earlier package TLS and storage evidence remains separate. Full hardware acceptance and R1 signoff remain open.

Test/documentation only; no product code changes. Xcode restored to Beakr / 360-iPhone-Dev without launching the live app. No live device/profile/membership/router changes, staging or commits; iPhone 18 Pro untouched. Historical E4 failure and successful retest retained.


Cancelled composer draft leaked into New Message — November 1

User found a bug on physical iPhone-Dev, XYZ Inbox: tapping Compose opened a new-message dialog containing stale body text "Dad", apparently from the earlier cancelled-reply check. That earlier PASS established original unread-state preservation and no sent reply only; it did not test draft disposal. Preserve that scoped observation alongside this newly reported failure. Actual app restart acceptance was interrupted by this bug and is not marked complete.

Cause: sheet dismissal called clearReplyContext, which removed only the original-message association; messageText and destinationID remained in the shared MessageComposerModel. New-message buttons presented the same model without resetting the draft. Added discardDraft to clear all three fields. Mac composer, iOS mailbox composer and iOS detail Reply sheet use it on dismissal; New Message buttons call it before presentation. iOS Send dismisses only after the body clears on successful queue admission, preserving a failed-send draft in its open dialog (Mac already had that guard). Reply/Forward/Send Again preparation remains intact.

Added discardedDraftDoesNotLeak with reply/forward/resend variants: type "Dad", discard, verify empty body/no recipient/cannot-send/original unread/no host request; repeat the reset used by Compose; send a fresh message to the same peer; verify only the fresh body is sent and the original is not marked read. Existing replyReadOnAdmission cancellation scenario now invokes discardDraft. No UI automation was run.

Validation: baseline Xcode BuildProject(buildForTesting: true) passed. RunSomeTests reported seven passed cases, zero failures/skips, on Beakr-R1-Contract-Baseline-20261026 only: three discardedDraftDoesNotLeak variants, replyReadOnAdmission cancel variant, queueMessage, sendOnlineMessage and hostFailure. Although the parameterized replyReadOnAdmission function was selected, the returned result reports only its cancel variant; do not claim all eight variants ran here. Bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_17-04-41--0500.xcresult. Final Mac and 360-iPhone-Dev BuildProject passed. git diff --check passed.

User visual retest pending: Run updated Beakr on 360-iPhone-Dev, start a reply to an unopened message, type distinctive text, Cancel, then open Compose from XYZ Inbox. Verify empty body and no preselected recipient; original remains unread and no reply was sent. Also verify dismissing a typed new-message sheet does not populate the next Compose. Xcode left on Beakr / 360-iPhone-Dev; assistant did not launch/install on the live phone. No live membership/profile/router changes, staging or commits; iPhone 18 Pro untouched. Full R1 signoff remains open and earlier E4 failure/retest retained.


Cancelled-draft visual retest — user-observed PASS, November 1

Following the instruction to Run the updated build on 360-iPhone-Dev, start a reply, type "Dad", Cancel, and open Compose in XYZ Inbox, user reported "pass". Record user-observed PASS for the requested check: new Compose has an empty body and recipient, and the original remains unread. This closes the reported cancelled-reply draft leak for the exercised path. Separate swipe-dismiss and cancelled-new-message visual variants were not explicitly confirmed. Preserve the original stale-text failure and the earlier narrowly scoped unread-state PASS.

Documentation only; no additional builds/tests, code edits, assistant live-device actions, profile/membership changes, staging or commits. iPhone 18 Pro remains untouched. The interrupted app restart acceptance and full R1 signoff remain open.


App restart inbox preservation — user-observed PASS, November 1

User reported "pass" to the resumed checklist: send R1-Restart-1 from physical iPhone-Dev to iPhone 17 Pro, open and reply, fully close and reopen Beakr on iPhone 17 Pro only, confirm the original appears once and remains read, then send R1-Restart-2 from iPhone-Dev and confirm it arrives once without Refresh. Record user-observed PASS for this exercised app restart/history/read-state and subsequent delivery check. This closes the restart check interrupted by the cancelled-draft bug. It does not establish an ambiguous-send retry across process restart or full hardware negative-trust acceptance.

Documentation-only follow-up; no additional builds/tests, code edits, assistant live-device actions, profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Prior failures and scoped retests remain preserved. Full R1 signoff remains open.


Queued message survives sender restart — user-observed PASS, November 1

User reported "pass" to the R1-Queue-Restart-1 checklist: close Beakr on iPhone 17 Pro; send from physical iPhone-Dev and observe Queued; fully close/reopen Beakr on iPhone-Dev while iPhone 17 Pro remains closed; confirm the message remains Queued in Outbox; reopen Beakr on iPhone 17 Pro and confirm exactly one received copy and sender transition to Sent Items without Refresh or resend. Record user-observed PASS for durable outgoing queue preservation across sender app restart and automatic delivery on recipient return. No measured recovery latency or captured message identifiers were supplied. This does not establish receiver restart after acceptance but before acknowledgement, controlled packet loss, or full negative-trust hardware acceptance.

Documentation-only follow-up; no new code, builds/tests, assistant live-device actions, profile/membership/router changes, staging or commits. Mac authority remained the instructed XYZ baseline; iPhone 18 Pro remains untouched. Historical failures and scoped retests preserved; full R1 signoff remains open.


Receiver recreation after saved message / lost acknowledgement — November 1

Added BeakrTests.receiverRestartAfterLostAcknowledgement. First phase uses real AuthenticatedTransportRouteOwner, session delivery, ApplicationMessageInbox, PersistentDataState and sender messaging model with injected in-memory links. The first acknowledgement is deliberately dropped. A fixture signal after inbox.record returns establishes storage completion; sender still has one queued durable envelope and receiver has one persisted message. The test then disables old routes and recreates receiver store/inbox/session/coordinator/driver/owner and both links. Sender session, store and model remain alive.

The production two-second ApplicationDeliveryPipeline retry loop resends the identical original envelope through the replacement route, without test-invoked retryPending or acknowledgement clearing. The new receiver session accepts it (its duplicate history was lost), but the reopened ApplicationMessageInbox suppresses duplicate storage/notification using restored message IDs. Production acknowledgement handling clears the durable sender queue and transitions the model to Delivered. Reopening both stores proves empty outgoing queue and one original incoming result; incoming file bytes remain unchanged. A distinct follow-up observer-barrier message proves the stream contains only restored-original then new-barrier events, with no duplicate new-message event for the retry. The barrier intentionally adds a second legitimate message after the one-copy disk checks.

Validation: baseline Xcode BuildProject(buildForTesting: true) passed. RunSomeTests reports three passed cases on Beakr-R1-Contract-Baseline-20261026 only: receiverRestartAfterLostAcknowledgement, inboxRestartSuppressesRetry and automaticDeliveryRecovery(false); zero failures/skips. The parameterized automaticDeliveryRecovery function was selected, but this result lists only false, so no rerun of true is claimed. Bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_17-21-09--0500.xcresult. git diff --check passed.

Scope: receiver-component recreation after confirmed storage and lost acknowledgement, not OS process termination, real TLS/discovery reconnect, or full hardware runtime. Inspection found AuthenticatedTransportRouteOwner currently transmits acknowledgement before awaiting incomingEnvelopeSink. This test deliberately drops that acknowledgement and waits for storage; it does NOT establish crash safety when an acknowledgement reaches the sender before receiver persistence completes. That ordering is an open potential data-loss window requiring separate investigation before signoff, not a reproduced loss in this run. No product code changed.

Test/documentation only. Xcode restored to Beakr / 360-iPhone-Dev without live app launch/stop. No live device/profile/membership/router changes, staging or commits; iPhone 18 Pro untouched. Historical E4 failure/retest retained. Full R1 signoff remains open.


Acknowledgement-before-persistence loss reproduced and fixed — November 1

The new isolated app test inboxSaveFailureRetainsSenderQueue obstructs only its temporary incoming-file destination with a directory, forcing atomic persistence to fail. BEFORE the fix it reproduced all three failures: receiver sent acknowledgement despite failed write; PersistentDataState retained an unpersisted in-memory incoming result; sender durable queue became empty (expected one). Failed result bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_17-27-30--0500.xcresult. This upgrades the previously noted ordering risk to an isolated reproduced message-loss failure. No live storage fault was induced.

Production changes:
- ProfileConnectionRegistry.IncomingEnvelopeSink now returns Bool: true means durable application acceptance; handlers must be idempotent. Its default is false (unhandled data is not acknowledged).
- AuthenticatedTransportRouteOwner invokes that sink for both accepted and duplicate application envelopes before sending acknowledgement. Protocol duplicate status alone cannot establish that an earlier application save succeeded. False, cancellation or superseded route generation withholds acknowledgement. Control acknowledgement/lifecycle/network-info handling remains separate.
- ApplicationMessageInbox.record reports successful persistence or an already-known persisted ID as true; missing storage, unsupported/invalid messages and save failures return false. Concurrent records for the same ID share one pending task, so they cannot independently save/publish. Attachment generation prevents an older profile's pending write from publishing into a newly attached inbox. The live ApplicationLANRuntimeManager returns this result to its connection registry.
- PersistentDataState.record rolls back its in-memory incoming entries, eviction order and idempotency index if atomic persistence throws, allowing the same ID to be saved on retry.

The app regression now proves no acknowledgement on write failure, no poisoned incoming result, one queued envelope in both live and reopened sender state, and successful recovery after repairing only the disposable path. Production retry/ack handling then stores exactly one receiver record, clears the durable sender queue, and marks Delivered; two identical send attempts and one acknowledgement are asserted. Receiver-recreation test now waits for the deliberately dropped acknowledgement AFTER the inbox callback, matching corrected ordering. concurrentInboxRetriesPersistOnce submits 16 same-envelope records and verifies all report success, one stored original and one new-message update, using a distinct observer barrier to detect extras.

Validation: baseline Xcode BuildProject(buildForTesting: true) passed. Five focused app cases passed on Beakr-R1-Contract-Baseline-20261026: inboxSaveFailureRetainsSenderQueue, receiverRestartAfterLostAcknowledgement, inboxRestartSuppressesRetry, automaticDeliveryRecovery(false), readReceipt. Bundle: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_17-30-32--0500.xcresult. The additional concurrentInboxRetriesPersistOnce case passed in /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7285357C-F5CD-4DA0-88DB-029CB8D9192A/RunSomeTests/Test-Beakr-2026.11.01_17-34-47--0500.xcresult. Six total focused cases, no failures/skips in final runs. Do not claim automaticDeliveryRecovery(true) ran in these results.

Package validation: Xcode BeakrNet-Package / My Mac build-for-testing passed. Seven DataPersistenceTests passed, including repeated failed incoming writes at capacity, restoration of the evicted entry/indexes, disk preservation, and same-ID recovery; log /private/tmp/Beakr-Ack-Persistence-20261101.log. Sixteen HostServicesTests passed; log /private/tmp/Beakr-Ack-Host-20261101.log. They ran through swift test --disable-sandbox under the workspace sandbox. The first combined filter returned only the Data suite, so the Host suite was run explicitly. Host acknowledgement test now explicitly supplies a successful application sink rather than relying on an implicit no-op. Final Mac and 360-iPhone-Dev BuildProject passed; git diff --check passed.

Scope: the isolated persistence-failure/retry regression is resolved in code. Atomic file replacement completion is the persistence boundary; no power-loss/fsync durability claim, full process-kill test, OS notification test, or physical storage-failure result is implied. Full R1 signoff remains open. User normal messaging smoke retest is pending on the updated phone: Run on 360-iPhone-Dev, receive a new Mac message, open/reply, confirm single-copy delivery both ways. No destructive live fault injection requested.

Xcode left on Beakr / 360-iPhone-Dev. No live app launched/stopped by the assistant, no live profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Existing changes and historical E4 failure/successful retest preserved.


Acknowledgement/persistence fix — normal messaging smoke retest PASS, November 1

User reported "pass" after the requested Run on 360-iPhone-Dev, sending a new message from Mac to the phone, opening it and replying, and confirming each message arrives once. Record user-observed PASS for this normal messaging smoke retest of the updated phone. This supplements the isolated reproduced save-failure regression and passing automated recovery tests; it does not establish physical storage-failure recovery, power-loss durability, or that other live participants have been updated. Full R1 signoff remains open.

Documentation-only follow-up. No additional builds/tests, product-code changes, assistant live-device actions, profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Historical failures and scoped retests remain preserved.


Mac messaging smoke PASS; context-menu Reply target bug — November 1

User reported "pass" after the requested update/Run on Beakr / My Mac and R1-Mac-Persistence-1 message from iPhone-Dev to Mac, opening/replying and confirming single-copy delivery without Refresh. Record this normal messaging smoke check as user-observed PASS; no physical storage-failure result is implied.

In the same response, user reported a separate bug: on Mac, right-clicking a new unread message in Column 2 shows Reply, but selecting Reply does nothing. Inspection found MacMessageList.selectionContextMenu receives the right-clicked routes but invokes a zero-argument reply callback. That callback reads selectedDetailRoute/selectedMessage instead of the context-menu target. With no selected incoming detail it returns without presenting the composer; with a different selected message it can target the wrong message.

Fixed ContentView.swift: MacContextList/MacMessageList Reply and Reply All callbacks now carry the targeted incoming UUID. The parent resolves that message directly, checks active-network and addressable-recipient eligibility, prepares the reply and opens the composer. Toolbar Reply still resolves its selected message then uses the same helper. Context-menu Reply/Reply All are disabled when that specific message is ineligible. No detail selection change is used to trigger Reply, so merely starting the reply does not mark an unopened original read.

Validation: Beakr / My Mac Xcode BuildProject passed; git diff --check passed. UI callback-wiring change only; no automated tests or live app launch by the assistant for this fix. Earlier test passes do not cover this subsequent change. Xcode intentionally left on Beakr / My Mac for user Run and visual retest.

Retest pending: Run on My Mac, right-click an unread Column-2 message without first opening it, choose Reply and confirm a composer opens addressed to its sender with an empty body. Also exercise right-clicking a message different from the currently selected detail to verify correct targeting. Cancel should preserve unread state; successful reply should mark the target read and arrive once. No live profile/membership/router changes, staging or commits; iPhone 18 Pro untouched. Full R1 signoff remains open and prior failures/retests retained.


Mac context-menu Reply — user-observed PASS, November 1

User reported "pass" after the requested Run on Beakr / My Mac, right-clicking an unread Column-2 message without opening it, choosing Reply, confirming the composer opens with the correct recipient and an empty body, then sending and confirming delivery. Record user-observed PASS for that exercised context-menu Reply path. The separately suggested different-selected-detail, Reply All and cancellation variants were not explicitly confirmed. Preserve the original no-op Reply failure alongside this successful retest.

Documentation-only follow-up; no new code, builds/tests, assistant live-device actions, profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Full R1 signoff remains open.


Mac context-menu Reply with a different selected message — user-observed PASS, November 1

User reported "pass" to the targeted checklist: keep a message from iPhone-Dev open on Mac, receive a fresh message from iPhone 17 Pro, right-click that new message in Column 2 without opening it, choose Reply, confirm iPhone 17 Pro is the recipient, send, and confirm one reply arrives on iPhone 17 Pro rather than iPhone-Dev. Record user-observed PASS for correct context-menu reply targeting independently of the selected detail. This closes that specific follow-up to the Mac Reply fix; it does not establish unperformed Reply All or cancellation variants.

Documentation-only follow-up; no new code, builds/tests, assistant live-device actions, profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Historical failures and scoped retests preserved; full R1 signoff remains open.


Mac cancelled Reply and clean Compose — user-observed PASS, November 1

User reported "pass" to the requested Mac checklist: receive a fresh message from iPhone-Dev and leave it unread; right-click Reply, type "Cancel-Mac", then Cancel; confirm the original stays unread and no reply arrives on iPhone-Dev; open Compose and confirm both recipient and body are empty. Record user-observed PASS for this Mac cancelled-reply/read-state/draft-disposal path. This complements the earlier physical-iPhone cancelled-draft retest; no additional UI variants are inferred.

Documentation-only follow-up; no new code, builds/tests, assistant live-device actions, profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Historical failures and scoped retests remain preserved; full R1 signoff remains open.


Mac context-menu Forward target correction — November 1

Following user authorization, corrected the remaining selection-dependent Forward callback in ContentView.swift. MacContextList/MacMessageList now pass the right-clicked incoming message selection to forwardMessage; the helper resolves that explicit message's body and prepares the composer. Toolbar Forward delegates to the same helper using its selected detail. Context-menu forwarding is disabled for an inactive network, and the helper rechecks active-network eligibility. Starting Forward does not alter detail selection or mark the original read. Existing prepareForward clears the recipient and inserts the forwarded body.

Validation: Beakr / My Mac Xcode BuildProject passed; git diff --check passed. Callback-wiring change only; no automated tests or live app launch by the assistant for this change. User visual retest pending: select message A, right-click a different message B, choose Forward, and confirm B's body appears with an empty recipient; select a recipient, send and verify the forwarded B content arrives. Xcode left on Beakr / My Mac for Run.

No live device/profile/membership/router changes, staging or commits. iPhone 18 Pro untouched. Earlier results do not cover this subsequent change; original failures and scoped retests remain preserved. Full R1 signoff remains open.


Mac context-menu Forward targeting — user-observed PASS, November 1

User reported "pass" to the requested updated-Mac checklist: select message A, right-click a different message B and choose Forward, confirm the composer contains B's text with no recipient, choose iPhone-Dev, send, and confirm B's forwarded text arrives. Record user-observed PASS for the exercised explicit context-menu Forward target and delivery path. No additional variants are inferred.

Documentation-only follow-up; no new code, builds/tests, assistant live-device actions, profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Historical failures and scoped retests remain preserved; full R1 signoff remains open.


R1 signoff audit — November 1

Reconciled current evidence in Packages/BeakrNet/Documentation/R1-Signoff-Audit-2026-11-01.md. Final signoff remains open. Recent Compose/Reply/Forward and message-opening defects have scoped user PASS results; acknowledgement-before-persistence loss has a reproduced regression, fix and passing isolated recovery plus normal-device smoke evidence. Remaining work is final-build inventory, full-path negative-trust evidence, controlled E11 impairment, explicit remaining matrix variants/resource evidence, and the user-planned independent authority hosting before final signoff. Earlier pending notes are superseded only where later scoped passes exist. No new test or hardware pass is claimed. Preserve original E4 and other failures alongside retests.

Audit is documentation-only: no code/build/test/device/profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Next: prepare the build/evidence inventory and disposable negative-trust run specification without disrupting XYZ.


Negative-trust run preparation and source inventory — November 1

Prepared Packages/BeakrNet/Documentation/R1-Negative-Trust-Run-2026-11-01.md: current source/config fingerprint, Xcode OS/destination inventory and a concrete two-phase disposable HTTPS-refresh → production TLS admission → durable-storage test specification for E2/E9. Current scheme remains Beakr / My Mac. Installed simulator build identities remain unverified; sandboxed simctl enumeration failed, with no service/device restart. The specification identifies direct-fixture revocation and storage-bridge limits and does not claim hardware acceptance. No test fixture implemented/run, builds, live app/listener/profile/membership/router changes, staging or commits. iPhone 18 Pro untouched. Next: implement the isolated fixture; no user device action needed yet.


HTTPS-refreshed production TLS negative-trust integration — November 1

Implemented RefreshedTrustTLSIntegrationTests.swift as an opt-in test in ProductionLANTLSIntegrationTests. Disposable authority/CA/node identities and files, loopback listeners, memory-only TLS identity imports; no live XYZ profile/keychain data. Package test dependencies now include BeakrNetHost and BeakrNetOperations. Existing certificate/TLS and curl test helpers are shared internally; certificate generation accepts an optional DNS SAN for the HTTPS fixture. No product-source behavior changed.

Source review corrected a preparation assumption: AuthorityHTTPSServer is private to its executable. The new test uses a test-owned loopback HTTPS listener with production AuthorityServerTLSConfiguration, AuthorityHTTP1Codec and the AuthorityTrustStateCoordinator's signed endpoints. Curl validates its CA/hostname. The listener omits the executable's admission/audit router; its HTTP 503 outage gate is controlled service unavailability, not raw packet loss or process termination. The fixture performs approve/removeAndRevoke only on its own disposable authority.

Passing evidence:
- Eligible control peer delivers over production mutual TLS and signed LAN handshake to AuthenticatedTransportRouteOwner. Its Boolean sink persists through PersistentDataState before a real wire acknowledgement clears the fixture sender's durable queue.
- Observer verified membership generation 2 lacks candidate C while authority has approved C. During 503 outage, the production acceptedPeerResolver rejects C's real TLS certificate key; no application handshake/route/sink is entered, receiver bytes remain unchanged, and the same envelope remains queued. One recovery attempt issues two HTTP requests; ten immediate additional misses issue zero additional requests.
- After restoring service and waiting 2.1 seconds for the production miss-recovery deadline, a harness-created connection drives automatic signed refresh in revocation-before-membership order, advancing generation 2 to 3. The original queued message ID is then admitted, stored and acknowledged. All positive-phase outgoing entries clear.
- After fixture C is removed/revoked, verified HTTPS revocation refresh takes effect even while membership fetch returns 503. The production membership resolver excludes C. A deliberate test-only bypass of that already-failed resolver independently exercises LANTransport authentication and requires exact revokedCredential rejection over successful production mutual TLS. A fresh payload cannot invoke the sink, change receiver bytes or clear its pending queue entry.
- Following successful removal-membership refresh, observer trust/controller/store objects reopen from disk with authority unavailable. C's old credential is rejected again using a second fresh payload, while the unchanged eligible control peer still delivers.
- Reopened receiver storage contains exactly three authorized records with matching message IDs, full DataMessage content and idempotency keys. Reopened sender storage retains exactly the two rejected messages. Twelve authority HTTP requests were observed in this run. Positive sends attempt duplicate transmission, but the test does not independently require the second copy to reach the receiver before sender closure; the durable final count is established, not a new exact duplicate-processing count.

Validation: Xcode BeakrNet-Package / My Mac BuildProject(buildForTesting: true) passed after final edits. Focused SwiftPM opt-in run passed all 3 ProductionLANTLSIntegrationTests functions in 2.957 seconds; new refreshedTrustAdmission passed in 2.557 seconds. Log: /private/tmp/Beakr-Refreshed-Trust-20261101-final.log. Initial run also passed, then content/reopened-sender assertions were strengthened and rerun. No automated app tests or live app launches. git diff --check passed. Xcode restored to Beakr / My Mac.

Scope: connects real HTTPS signed refresh, production TLS/certificate extraction, membership resolution, signed credential rejection, production receiver route-owner acknowledgement ordering and durable storage. The listener, connection scheduling, application storage sink and sender acknowledgement-to-store bridge are test-owned. Unknown rejection is the production resolver's nil result before application authentication, not a LANHandshakeError named unknown membership. Revoked-handshake testing intentionally bypasses the rejected resolver only to prove defense in depth. Reopening is component recreation after a removal-membership refresh, not an OS process restart or stale-membership restoration test. No rendered app UI, complete ApplicationLANRuntimeManager, physical radio, full automated connection scheduler, or hardware E2/E9 signoff is claimed. Full R1 signoff remains open.

All test-owned listeners/connections and temporary credential/storage files are cleaned up. No live app/device/profile/membership/router changes, staging or commits. iPhone 18 Pro remains untouched. Earlier E4 failure and successful retest remain preserved. The earlier inventory fingerprint describes pre-fixture source and is not the identity of this changed source.


E11 physical-network feasibility — November 1

Prepared Packages/BeakrNet/Documentation/R1-E11-Network-Feasibility-2026-11-01.md after checking Microsoft, Linux bridge/NetEm and mDNS documentation. A ThinkPad merely joined to 360-Rogers does not intercept Beakr traffic. Candidate isolated topology uses a two-Ethernet-port Linux bridge between a spare test Mac and the Rogers LAN/test iPhone, with measured NetEm delay/loss and endpoint-specific authority outages. No hardware compatibility, spare endpoint availability or impairment pass is claimed. Asked user which spare Ethernet adapters/cables and Apple endpoints are available; no production network change or OS installation requested. Full E11 remains open. No code/build/test/device/router/profile/membership changes, staging or commits; iPhone 18 Pro untouched.


E11 tooling correction — Apple Network Link Conditioner, November 1

User correctly raised Apple's endpoint network-conditioning tools. Read-only filesystem inspection confirms /Library/PreferencePanes/Network Link Conditioner.prefPane is already installed on this Mac. Apple documents the macOS developer preference pane and iOS Developer Settings alternative (https://developer.apple.com/videos/play/wwdc2019/422/). Installation presence does not establish operational compatibility, enabled state, or that a chosen profile affects the actual Beakr LAN path. No conditioner enabled or settings changed.

The earlier conclusion that missing spare Mac/USB Ethernet hardware blocks E11 was premature. It blocks only the proposed external bridge topology. Evaluate the already installed Apple conditioner first; physical-iPhone Developer Settings may permit a narrower endpoint test without conditioning the authority Mac and its simulators together. Verify available controls and actual LAN effect before recording impairment evidence. The existing acceptance restriction against changing the production network still applies; activating impairment on a live endpoint requires an explicitly scoped test step. No purchase, Linux installation, router reconfiguration or independent-authority scope change is needed merely to investigate this option. iPhone 18 Pro remains untouched.


E11 endpoint conditioning and Mac reply navigation fix — November 1

Apple Network Link Conditioner delay profile: 100 Mbps each direction, 0% loss, 100 ms delay each direction, DNS delay zero. Mac route to physical iPhone-Dev 192.168.1.184 uses Ethernet en0; USB remains connected, but this IP probe route is LAN. Conditioner-OFF baseline ping: 5/5 received, min/avg/max 2.279/30.985/74.885 ms. Enabled delay profile: 10/10 received, 204.052/267.660/313.221 ms. User confirmed baseline exchange and the subsequent delay-profile message/reply, single receipt and responsive Compose/navigation, then OFF. Record scoped delay messaging/UI PASS. ICMP measurements establish the sampled LAN effect, not direct Beakr TCP path/packet tracing. Actual delay message shown later is E11-Delay-RealDelay.

Loss profile: 100 Mbps each direction, 5% configured loss each direction, zero added/DNS delay. Enabled sample to the same phone: 40 sent, 38 received, 5% observed round-trip ping loss; min/avg/max 3.987/4.943/7.075 ms. This sample is not a per-direction or Beakr TCP loss measurement. User turned conditioner OFF. Instead of the suggested Mac-origin sequence, user sent 1/2/3 from phone to Mac, then replied from Mac. User suspected order/duplicates and reported each reply moved Mac to Sent Items. Run remains INCONCLUSIVE for full loss acceptance; do not count as PASS. Later screenshots show one visible row each 3/2/1 in Mac Sent Items and phone Inbox; user says order now looks correct. iPhone row repeats subject and preview, not evidence of separate duplicate messages. Earlier transient order concern remains unexplained. No delivery-ID audit or full queue/retry trace was obtained.

Source investigation confirmed Mac composer send explicitly switched sidebar to Sent Items/Outbox after every successful send. Fixed narrowly: MessageComposerModel exposes read-only hasReplyContext; Mac send captures that before model.send clears reply state, then skips automatic sidebar navigation for replies. Current mailbox/detail selection is not reassigned by successful reply send; unread filtering can still legitimately remove a now-read row. New-message/Forward navigation behavior retained. No transmission queue, sorting or deduplication changes. SwiftUI dataflow guidance applied.

Validation: Beakr / My Mac Xcode BuildProject passed (BuildProject-Log-20261101-201757.txt); git diff --check passed. Build only, no automated tests or assistant live app launch. User visual retest pending with conditioner OFF: Run updated Mac, select Inbox, reply to a fresh phone message, confirm Inbox remains selected and reply arrives once. Xcode left on My Mac. Existing changes/staging preserved; no reset, membership changes or commits. iPhone 18 Pro untouched. E11 intermittent-authority and full signoff remain open.


Mac reply preserves Inbox — user-observed PASS, November 1

User reported “fixed” after the requested updated-Mac Run and conditioner-OFF fresh iPhone-Dev → Mac Inbox reply retest. Record user-observed PASS for preserving Inbox selection and the requested single reply delivery. Only Mac needed updating for this navigation correction; no new iPhone build or automated test is implied. Earlier packet-loss run remains INCONCLUSIVE, including the transient ordering/duplicate concern; screenshots did not establish duplicate delivery. No new loss acceptance or full E11/R1 signoff. Documentation only; no live device/profile/membership changes, staging or commits. iPhone 18 Pro remains untouched.


E11 loss retest PASS; authority-outage procedure prepared — November 1

After the Mac reply-navigation fix, user confirmed the requested E11-Loss retest and switched Network Link Conditioner OFF. Procedure: physical iPhone-Dev sent Loss-Retest-A/B/C to Mac; Mac opened and replied Reply-A/B/C respectively; each arrived once, Inbox stayed selected and navigation remained responsive. Record scoped user-observed PASS under configured 5% uplink/downlink loss, 100 Mbps each way, no added/DNS delay. Prior 40-ping sample observed two missing replies on the Ethernet-to-phone path; no concurrent TCP trace or retransmission-count claim. Original loss run remains INCONCLUSIVE with transient order/duplicate concern and the subsequently fixed folder switch preserved. No full E11/R1 signoff.

Next prepared, NOT RUN: two ordinary Mac-Beakr quit/reopen cycles with conditioner OFF, physical iPhone-Dev and specifically iPhone 17 Pro on XYZ. Each outage lasts at least 20 seconds; during it exchange a uniquely labelled message/reply between the remaining peers and queue a separate phone-to-Mac message. Reopen Mac Beakr on XYZ; check automatic single-copy queued delivery within 60 seconds, then repeat with new labels only if the first cycle succeeds. Keep both peer apps running, do not Refresh or resend; stop on unexpected results. Mac OS/Ethernet stay running. Quitting Mac Beakr withdraws both authority and Mac messaging; this is a scoped repeated-host-outage run, not an independently filtered HTTPS endpoint. Existing cached trust can permit peer messaging without a new authority request, so this run alone cannot certify actual failed authority fetch/retry/verified-refresh timing. Earlier isolated refresh tests remain supporting evidence. No changes to profiles/memberships, simulator assignments or iPhone 18 Pro.

Documentation only in this preparation; no builds/tests/live app actions by the assistant, staging or commits. Xcode remains Beakr / My Mac.


Authority-outage peer-delivery FAIL; stale handshake evidence — November 1

With conditioner OFF and Mac OS running but Mac Beakr quit, user reports iPhone 17 Pro has remained foregrounded for over an hour, yet physical iPhone-Dev lists simulator peers Offline and its attempted Authority-Off-1 remains queued. Record FAIL for this peer-delivery step; do not continue the second outage cycle or erase prior successful E1 observations.

Read-only diagnostics identified attached physical iOS process PID 10646, remote-ios target, launch ref 78d603de00. Its peer counts oscillate 0→1/2→0 roughly every 30 seconds. Incoming signed transport authentication succeeds for peer 66D45727-F322-5C23-86CA-8CCC1540AA67 and another peer, followed almost immediately by connectionClosed. Authority requests time out and retry. No debugger pause/restart performed.

After sandboxed simctl enumeration failed, approved elevated read-only enumeration identified exact iPhone 17 Pro UDID 8A655C12-31F0-4AFD-967B-F8DB8E92AC05. Its log show (PID 48863) repeatedly reports transport authenticationFailed reason staleRevocationSnapshot followed by 30-second reconnectScheduled; authority requests fail because Mac authority is unavailable. Log: /private/tmp/Beakr-Authority-Outage-17Pro-20261101.log. No simulator app launched/stopped. iPhone 18 Pro not targeted or modified.

Source lead: ApplicationLANRuntimeManager passes currentRevocationSnapshot once into AppleProfileLANRuntimeFactory; the factory creates LANTransportConfiguration and ProfileLANConnectionController captures it in its authentication closure. This is a concrete stale-startup-snapshot mechanism to investigate against later distributor refresh. LANHandshakeAuthenticator freshness bound remains 86400 seconds (plus allowed skew); do not weaken it. Actual retained snapshot timestamp and last successful simulator refresh have not yet been measured, so precise cache provenance remains unproven. Next controlled observation: reopen only Mac Beakr on XYZ, leave both peers untouched, observe queued delivery for 60 seconds without Refresh/resend, then investigate/fix snapshot refresh wiring with a focused regression. No code changes/build/tests/staging/commits in this diagnostic step.


Refreshed handshake snapshot fix — November 1

User reports that after Mac Beakr returned, iPhone is XYZ Online but the original message remains in Outbox. Recovery is not established. The observed staleRevocationSnapshot failures and startup-captured configuration led to a reproducible package regression: a retained controller still rejected handshakes after its verified distributor received fresh evidence.

ProfileConnectionRegistry now exposes its distributor's current snapshot internally; ProfileLANConnectionController constructs each new handshake configuration with that snapshot. Identity, authority key, profile/environment, certificates, capabilities, clock, signature/freshness/revocation rules and post-handshake registry admission remain in force. No 24-hour freshness extension. Actual live snapshot timestamps remain unmeasured.

New HandshakeSnapshotRefreshTests.swift uses real TLS and one retained controller: old snapshot rejects; publishing fresh signed evidence permits admission; publishing revoked evidence rejects the credential. Before the fix this test failed at refreshed admission and reported stale instead of revoked in the final phase. After the fix all four ProductionLANTLSIntegrationTests passed (3.089 seconds), including the refreshed HTTPS trust/persistence test. All 16 HostServicesTests passed. Logs: /private/tmp/Beakr-Handshake-Refresh-before-20261101.log, /private/tmp/Beakr-Handshake-Refresh-after-20261101.log, /private/tmp/Beakr-Handshake-Host-after-20261101.log.

Xcode package build-for-testing and Beakr BuildProject for My Mac, 360-iPhone-Dev, and iPhone 17 Pro passed. App build log suffixes: 20261101-205033, 20261101-205107, 20261101-205151. git diff --check passed. No app launch, automated app test, or live interactive verification performed for this fix. Existing work preserved; no staging or commits; iPhone 18 Pro untouched.

Xcode left Beakr / iPhone 17 Pro (identified simulator UDID 8A655C12-31F0-4AFD-967B-F8DB8E92AC05). Next: user Run updated 17 Pro while Mac Beakr hosts XYZ and conditioner stays OFF; preserve original queued message, no Refresh/resend, observe delivery within 60 seconds. This deployment restart alone cannot prove automatic refresh in a retained live runtime; package regression covers that mechanism, and live authority-outage acceptance must be repeated after updating participating builds. E11/signoff remain open.


User-observed authority-outage/recovery retest PASS — November 1

After running the updated iPhone 17 Pro, user confirmed the original queued message delivered immediately at startup. This is deployment recovery, not by itself proof of retained-runtime refresh. User then reported physical iPhone-Dev online (and clarified it was already online before); that status alone does not independently identify its installed build.

With Network Link Conditioner instructed OFF and only Mac Beakr quit (Mac OS kept running), user reported PASS for iPhone-Dev to iPhone 17 Pro messaging and reply. For Authority-Return-Retest-1, user explicitly observed queued while Mac Beakr was closed, immediate delivery when Mac Beakr reopened, and clearance from iPhone Outbox.

Second peer exchange with Mac Beakr stopped was reported PASS. User had missed the Mac-directed part of that cycle, so only that part was repeated: quit Mac Beakr, send Authority-Return-Retest-2 and verify queued, reopen Mac Beakr on XYZ, check one arrival and Outbox clearance within 60 seconds without Refresh/resend. User responded "Pass... it arrived immediately on starting Mac Beakr." Record user-observed PASS against that requested check; no independent message-ID or packet trace collected. No Mac OS shutdown was required or reported completed.

Two peer-outage exchanges and two authority-return delivery checks now have user-observed passing results. Retain the preceding staleRevocationSnapshot failure and package regression evidence. These short cycles do not establish a 24-hour live freshness-boundary soak or full R1 signoff. No additional code/build/test/device action in this recording step; all existing changes preserved, no staging/commits, iPhone 18 Pro untouched. Leave Mac Beakr running on XYZ and conditioner OFF for the next acceptance review.


### Mac idle reconnect investigation — November 1, 2026

Mac PID 88351 sample at 21:20:15: 1,675 of 1,917 main-thread samples were in the run-loop Mach wait (approximately 87%; not a process CPU percentage). The saved unified-log excerpt `/private/tmp/Beakr-Mac-idle-log-20261101.txt` contains 114 Runtime [RETRY] records over approximately two minutes. The application maps Bonjour reconnectScheduled to that marker; identifying details are private/redacted. Root cause and peer remain unconfirmed.

Read-only investigation found a possible interaction between per-endpoint discovery retries and same-peer transport replacement. A temporary Network.framework Bonjour browser at approximately 21:29 returned four results with four distinct node IDs; each result grouped its interfaces. Thus duplicate endpoints for a node were not observed, and that hypothesis is not established for this live incident. No live app was restarted or debug-attached; no memberships or archived iPhone 18 Pro state were changed.

Focused package validation: `swift test --disable-sandbox --filter 'HostServicesTests/replacementLANConnection|BonjourDiscoveryTests'` passed 18 tests in two suites. Log: `/private/tmp/Beakr-idle-connection-checks-20261101.log`. Existing tests cover replacement ownership and authentication-dependent backoff, but do not establish the cause of the live disconnects. No production behavior change made. Next evidence needed: a short Mac debugger console capture covering transport authentication, pathLost/disconnect reason, and reconnect scheduling. E6 idle energy remains open.


### Idle reconnect cause and bounded retry fix — November 1, 2026, 21:43

User-provided Mac console capture after a debugger launch at 21:40:16 establishes repeated authentication of peer 35A51E3A-B2DB-58D8-AEB0-1C5D6780317B, immediate connectionClosed, one-second reconnect scheduling, and peer-count/UI churn between two and three. A read-only iPhone 17 Pro Max simulator log capture (device 45367EFE-5644-45C6-9150-D0160C579819, Beakr PID 42633) shows repeated staleRevocationSnapshot authentication failures at the matching cadence. Evidence: /private/tmp/Beakr-17ProMax-idle-20261101.log. This is consistent with that simulator retaining the older startup-snapshot handshake implementation; its installed build version has not independently been inventoried. Earlier updated Mac/Dev/17 Pro recovery passes remain scoped to those participants.

Fixed a separately reproduced retry-policy defect in BonjourDiscoveryCoordinator: successful authentication no longer immediately resets retry history. A connection must remain authenticated for 30 seconds before its subsequent disconnect resets backoff. Short-lived authenticated connections retain exponential retry delays capped at the existing 30 seconds. This uses monotonic timestamps, introduces no timer task, and leaves authentication/revocation checks intact.

Regression shortLivedAuthenticatedConnectionsBackOff failed before the change with delays [2,2,2,2] ms instead of [2,4,8,8] ms, and passes after. Existing sustained-recovery test now explicitly uses a shortened stable interval. Focused Bonjour/HostServices run passed 19 tests in two suites; Xcode BuildProject succeeded (BuildProject-Log-20261101-214241.txt). Logs: /private/tmp/Beakr-idle-backoff-before.log and /private/tmp/Beakr-idle-backoff-after.log.

Deployment/idle verification pending: run current build on iPhone 17 Pro Max and My Mac, then verify peer stability and lower idle activity. No live app was relaunched by the assistant, no profile/membership reset, and archived iPhone 18 Pro remains untouched. The retry fix bounds repeated failures; it does not by itself repair the rejecting peer. E6 remains open pending live confirmation.


### Post-update idle observation — November 1, 2026, 21:49

User confirms iPhone 17, 17 Pro, and 17 Pro Max simulator apps updated; archived iPhone 18 Pro not touched; Mac remains running. Mac session ref 78e7052a00, PID 95804: formerly cycling peer 35A51E3A-B2DB-58D8-AEB0-1C5D6780317B authenticated at 21:48:07, bringing peer count to four. Re-reading the Mac console at approximately 21:49:37 shows no subsequent pathLost, authenticationFailed, reconnectScheduled, or peer-count changes. This is approximately 90 seconds of observed stability after the last admission. Read-only top measurement at 21:49:37 reports 0.1% CPU over a five-second interval, 63 MB memory, eight threads. This supports recovery from the rapid idle reconnect/UI churn; it is a short observation, not a long-term energy or leak certification. Earlier user Mac log independently confirms revised backoff delays 1,2,4,8,16 seconds while the old peer was still failing. No additional code changes or live restarts in this verification.


### E7 sender switches networks with queued work — user-observed PASS, November 1

User reported “Pass ... Imediately” against the requested Sender-Switch-1 procedure: quit only iPhone 17 Pro Beakr; physical iPhone-Dev queues a message to it on XYZ; sender switches to Hamilton and the XYZ message is absent from Hamilton Outbox/history; reopen recipient on XYZ while sender remains on Hamilton and verify no delivery; return sender to XYZ without Refresh/resend. Record scoped user-observed PASS: immediate single delivery on return, XYZ Outbox clears, no Hamilton leakage. Timing is qualitative; no independent message-ID trace. Mac remains on XYZ, conditioner instructed OFF, archived iPhone 18 Pro untouched. This extends the earlier recipient-switch pass; it does not certify every simultaneous-submission interleaving or full R1 signoff. Documentation only.


### E8 repeated pending invitation import — user-observed PASS, November 2, 2026

Controlled run on R1-E8-Test (network C1C3928F-DC59-4C83-AE81-9A3B529A6DC8), with Mac hosting its active authority and Network Link Conditioner visually confirmed OFF. Mac/iPhone 17 Pro baseline messaging was reported successful. User inadvertently completed iPhone 17 enrollment, then used iPhone 17 Pro Max as the pending applicant; preserve all these memberships. iPhone 18 Pro remained outside the procedure.

Applicant node A29ED7E5-8597-5F13-817B-93A6080B7532, request 6D9A4BC7-4142-4D75-B26C-C18E88510D9B. Initial repeated paste from uncertain clipboard contents produced Invitation Cannot Be Reviewed, NSCocoaErrorDomain 4864; this remains an observed format error with unestablished clipboard provenance, not evidence of a deduplication failure. After recopying the existing invitation, review opened. User clicked Join again while pending; screenshots show the same request and node, one pending row, and Awaiting Approval. Mac approved that exact request after local password authentication. Applicant returned to the root screen with R1-E8-Test active. User reported all four devices converged online in less than 15 seconds; screenshots confirm four online on each participant.

User reported PASS for applicant-to-Mac and applicant-to-iPhone 17 Pro message/reply checks, single delivery and Outbox clearance without Refresh/resend. Visible outgoing labels: E8-Max-to-Mac-1 and E8-Max-to-Pro-1; visible Mac reply used abc rather than the proposed label. No independent message-ID trace obtained. Final 18:57 screenshot shows exactly one iPhone 17 Pro Max Registered history entry (18:49), alongside separate iPhone 17 and iPhone 17 Pro entries. Member list also showed one applicant node with its friendly name restored.

Record scoped user-observed PASS for repeated pending-import request identity preservation, visible membership/history deduplication, approval completion/root navigation, and subsequent messaging. This does not prove installation executed exactly once internally or establish approved-during-install interruption; no already-passed shutdown/recovery test was repeated. No full R1 signoff.

Return to XYZ remains PENDING at this recording: Mac and three participating simulators still on R1-E8-Test. Restore existing XYZ selections, retain test profiles/history, and verify a message exchange after restoration. No assistant app launches, builds, automated tests, revocation, deletion, resets, staging or commits in this run. Existing workspace changes preserved.


### E8 return to XYZ — user-confirmed complete, November 2, 2026

Following the scoped repeated pending-import PASS, screenshot at 18:59 shows Mac XYZ active and R1-E8-Test inactive. User then confirmed completion of switching iPhone 17, iPhone 17 Pro, and iPhone 17 Pro Max to their existing XYZ memberships. User subsequently responded “done” to the requested Mac → Pro Max E8-XYZ-Return-1 and Pro Max → Mac E8-XYZ-Return-Reply-1 exchange, including single receipt and both Outboxes clearing without Refresh/resend. Record user-confirmed restoration and messaging check; no independent delivery-ID trace. Network Link Conditioner was instructed to remain OFF, following its earlier visual OFF confirmation.

E8 return/cleanup is complete. Retain R1-E8-Test profiles, memberships and evidence; no deletion or revocation requested or performed. iPhone 18 Pro remains untouched. This closes the restoration pending in the preceding entry, not full R1 acceptance or the separate approved-during-install interruption variant. Documentation-only assistant action; existing workspace/staging preserved, no builds, automated tests, resets, staging or commits.


### E6 Mac idle resource observation — November 2, 2026, 19:06–19:23

User supplied Activity Monitor baseline, midpoint and final screenshots for the same Mac Beakr PID 98275 after XYZ restoration. Procedure requested Mac and participating simulators idle on XYZ, conditioner OFF, no restarts and no Mac sleep. CPU samples at 19:06:12 / 19:14:08 / 19:22:58: 0.2% / 0.3% / 1.0%; cumulative CPU time 5:21.20 / 5:22.67 / 5:24.38. The 3.18 CPU-second increase across 1006 wall seconds corresponds to approximately 0.32% of one core on average, assuming the requested continuous awake interval. Instantaneous 1.0% final CPU is not the interval average.

Memory samples at 19:06:52 / 19:14:18 / 19:23:02: 111.8 / 105.4 / 105.4 MB. Threads were 7 in the initial CPU screenshot, 8 in initial Memory and all subsequent selected-process samples. Ports 517 / 520 / 516; these are Activity Monitor ports, not network connection counts. Memory decreased 6.4 MB then remained unchanged at displayed precision; sampled threads and ports show no sustained growth.

Record scoped satisfactory idle-resource observation across approximately 17 minutes, with no sampled memory/thread/port accumulation and low average CPU. This is not a leak certification, direct energy measurement, task/connection-count trace, or proof of no reconnect events between samples. No new continuous log or energy capture was provided; full E6/R1 signoff remains open. Assistant only appended documentation; no code/build/test/live-device actions, resets, staging or commits. iPhone 18 Pro untouched. Post-idle messaging check remains to be confirmed.


### E6 post-idle messaging — user-observed PASS, November 2, 2026

User reported “pass” for the requested post-idle Mac → iPhone 17 Pro Max on XYZ message/reply check, including single delivery and Outbox clearance without Refresh/resend. User clarified that clipboard contents placed an X post URL (status 2117232661873721356) in the message body instead of the proposed test text. Actual body is therefore recorded as that URL, not E6-Idle-End-1; URL content was not fetched or evaluated. This label/body deviation does not invalidate the delivery observation or establish a Beakr clipboard defect. No repeat needed. Post-idle functional check is complete; the preceding resource observation limitations and open full E6/R1 signoff remain unchanged. Documentation only; existing workspace/staging preserved, iPhone 18 Pro untouched.


### E6 Mac energy snapshot — November 2, 2026, 19:42

User screenshot of Activity Monitor Energy tab shows selected Beakr application: Energy Impact 0.4, 12 hr Power 1.63, App Nap No, Preventing Sleep No. This is application-level displayed evidence; this view does not show PID. Record low current displayed impact alongside the earlier approximately 17-minute PID 98275 CPU/memory/thread/port observation and passing post-idle message exchange. The 12 hr Power column is historical rather than a measurement restricted to the controlled idle window; these values are not reported as watts or percentages. One snapshot does not establish sustained energy behavior or retrospectively explain the earlier High-energy incident. Task/connection-count instrumentation and full E6/R1 signoff remain open. No additional lifecycle repetitions warranted by this snapshot alone. Documentation only; all existing changes and live memberships preserved, no staging/commits, iPhone 18 Pro untouched.


### E6 read-only socket trace and diagnostic availability — November 2, 2026, 20:02–20:03

Confirmed Mac Beakr PID 98275 executable path and continuing process. Four lsof TCP snapshots at 20:02:48, 20:03:08, 20:03:28 and 20:03:48 each show the same three ESTABLISHED socket endpoints/descriptors and two LISTEN sockets (8443 and 49933). Evidence: /private/tmp/Beakr-E6-sockets-20261102.txt. No sampled TCP accumulation during this one-minute window; sampling cannot exclude transient connections between observations or establish authenticated peer identity. This is OS socket evidence, not application task counts.

Xcode GetConsoleOutput reported no active launch session; no app was launched or debugger attached. Read-only unified-log query for PID 98275 over the preceding three minutes found no persisted reconnectScheduled, authenticationFailed or pathLost matches; missing debug retention/privacy limits mean absence is not proof of no events. Source inspection found connectionCount() on ProfileLANConnectionController and ProfileConnectionRegistry but no call sites in app/source exposing them as diagnostics. Bonjour coordinator owns private reconnect, discovery-loss and connection-attempt task dictionaries without a published task-count diagnostic. Running-app task-count evidence therefore remains unavailable through current exposed diagnostics. Closing it requires instrumentation and a subsequent controlled build/run, not more Activity Monitor screenshots. No code edits, app restarts, profile changes, staging or commits. iPhone 18 Pro untouched; full E6/R1 signoff remains open.


### E6 bounded runtime count instrumentation — November 2, 2026

Implemented read-only Sendable resource snapshots on BonjourDiscoveryCoordinator (owned connections, reconnect tasks, discovery-loss tasks, connection-attempt timeout tasks), ProfileLANConnectionController (active admitted transports and pending handshakes), and ProfileBonjourRuntimeService (combines owner snapshots). Each actor snapshot is consistent locally; the aggregate is sequential, not atomic across actors. Discovery connections overlap transport ownership and must not be summed. These are specific owned task handles, not a census of all Swift tasks or proof that cancellation has finished executing.

Debug macOS app now emits public count-only Runtime notice lines marked [RESOURCES], with a fresh non-profile trace UUID and sample ordinal 1/11 through 11/11. Uses the existing five-second network-info loop, first sample after approximately five seconds, then every sixth tick (approximately 30 seconds) through approximately five minutes. No added monitoring task, persisted settings, secrets, peer identifiers or addresses. Sampling stops after 11 lines per runtime start; cancellation suppresses the post-await log. Release and iOS app builds do not enable this trace. Runtime restarts create distinct trace IDs.

Validation: Swift Testing focused package command passed 16 HostServices tests plus 20 Bonjour tests (36 total test functions, parameterized executions additional). New resourceSnapshotLifecycle exercises pending attempt, ready cancellation of timeout, discovery-loss grace, rediscovery cleanup, queued reconnect and stop clearing all owned counts. Existing host admission/removal test now verifies active and pending snapshot counts. Log: /private/tmp/Beakr-E6-resource-tests-20261102.log. Beakr / My Mac Xcode BuildProject passed (BuildProject-Log-20261102-201046.txt). git diff --check passed. No automated app tests or live app launches performed. Existing workspace/staging retained; no reset/stage/commit; iPhone 18 Pro untouched.

Next phase, NOT RUN: user quit only Mac Beakr then Run Beakr / My Mac from Xcode, with XYZ active, peers unchanged, conditioner OFF. This briefly withdraws XYZ authority. Observe first [RESOURCES] sample and restored peers, then collect all 11 samples without Refresh/network switches. Xcode left Beakr / My Mac for this controlled run. Do not count build/tests as live acceptance or full E6/R1 signoff.


### E6 instrumented idle counts — scoped PASS, November 2, 2026, 20:14–20:19

Retrieved all 11 untruncated [RESOURCES] records directly from Xcode launch session 7bfabc6700, Mac Beakr PID 67177, trace 06698A82-D0E9-4A03-9F37-CAF33DCE7306. First sample 20:14:39.416, final sample 20:19:47.191 (approximately 308 seconds). Every sample shows discoveryConnections=3, activeTransports=3, pendingHandshakes=0, reconnectTasks=0, discoveryLossTasks=0, connectionAttemptTasks=0. Evidence saved to /private/tmp/Beakr-E6-resource-trace-20261102.txt. User initially could not see console output; tool retrieval and unified logging confirmed emission without another restart.

Scoped PASS for no sampled accumulation of the instrumented transport and owned timer/task categories during this idle run. This closes the missing idle count evidence for these categories, complementing earlier stable memory/thread/port measurements, low current energy and successful post-idle messaging. It does not count every Swift task, prove absence of events between samples, measure resource growth across repeated lifecycle cycles, or certify a long-duration leak soak. No full R1 signoff. No additional restart or simulator action during collection, no memberships changed; iPhone 18 Pro untouched. Existing workspace/staging preserved; documentation and temporary evidence only, no stage/commit.


### E2 fresh-network outage and automatic recovery — November 2, 2026

User created/activated R1-E2-Test on Mac, enrolled iPhone 17 Pro, and reported successful baseline messaging. Screenshot at 20:28 shows Pro's member list containing only itself and Mac; authority history marks Pro Registered (node prefix/suffix 6926DE91…E498D). User followed quit procedure before Pro Max enrollment; 20:29 screenshot shows Pro Home Screen and Mac alone online. Pro Max then joined and became Registered at 20:31 while Pro remained closed. R1-E2-Test network UUID and baseline signed membership generation were not independently captured.

User quit Mac Beakr. Read-only TCP probes to 127.0.0.1:8443 and 192.168.1.157:8443 both returned connection refused. Pro was reopened while Mac remained unavailable. Pro Max recipient picker showed Pro as Network Device 1BBE498D — Offline; user initially considered it missing, then selected the matching node-suffix entry. Screenshot at 20:38 shows one queued message on Pro Max and each phone alone online. This is a friendly-name presentation observation, not established routing failure.

Read-only simulator logs for exact Pro UDID 8A655C12-31F0-4AFD-967B-F8DB8E92AC05, PID 70035, show membership/revocation fetches failing with NSURLErrorDomain -1004 / connection refused, and Bonjour reconnect delays 1, 2, 4, 8, 16, then 30 seconds. Files: /private/tmp/Beakr-E2-Pro-outage-20261102.log and /private/tmp/Beakr-E2-Pro-outage-detail-20261102.log. Sandbox blocked CoreSimulator; approved elevated read-only captures succeeded. Detailed available logs did not expose explicit unknown-member rejection. Therefore strict E2 trust-negative cause remains NOT ESTABLISHED, not a full E2 pass.

User reopened Mac on R1-E2-Test and reported PASS against automatic original queued-message single delivery, sender Outbox clearance and all three devices online within the requested 60-second window, without Refresh/resend. Screenshot at 20:49 confirms three online on Mac/Pro/Pro Max, Pro Inbox 1 and Pro Max Sent 1 with clear Outbox. Exact user recovery latency was not supplied. Same Pro PID 70035 log shows Mac peer 1A254DA2-BEB9-56CC-BFDF-29DAB8F2AB0A authenticated at 20:48:58.690, membership activated(generation: 6) at 20:49:14.014, and Pro Max node 23E1277F-5742-50F9-BA69-EB27A75CEAB6 authenticated at 20:49:14.017. This directly supports membership activation and admission in the retained Pro runtime; time from Mac launch was not measured. Evidence: /private/tmp/Beakr-E2-Pro-recovery-20261102.log.

Record scoped user-observed automatic recovery/delivery PASS with membership activation/admission logs; explicit unknown-member rejection remains unproven. Reverse reply and return to XYZ still pending. Mac/Pro/Pro Max currently R1-E2-Test; iPhone 17 remained XYZ. No assistant restarts, membership removal, profile deletion, resets, staging or commits; iPhone 18 Pro untouched. Retain all test profiles and evidence.


### E2 reverse reply confirmed; paste report under investigation — November 2, 2026

User confirmed Pro → Pro Max recovery reply single receipt and Outbox clearance. Both directions now have user-observed recovery messaging passes. Strict unknown-member rejection remains NOT ESTABLISHED as above. User also reports Reply-body Paste does not insert the expected clipboard content; affected device, copy source and exact behavior requested before attributing cause. Initial source inspection shows iOS Reply and Compose share the standard SwiftUI TextEditor bound directly to model.messageText; reply preparation clears the draft before presentation, with no custom Reply paste handler found. No fix or reproduction claimed.

Acceptance is paused for this report. Mac, iPhone 17 Pro and iPhone 17 Pro Max remain on R1-E2-Test; restore their existing XYZ selections after investigation, retaining all test profiles/history. iPhone 17 remains XYZ and iPhone 18 Pro untouched. Documentation-only change at this point; no staging/commits.


### Paste investigation — physical device success and isolated simulator check, November 2, 2026

User reports copying E2-Recovery-Reply-1 from Xcode and repeated paste failure in simulator Beakr, while Xcode and Mac Beakr accepted paste. User also reports failed native editing-menu copy/paste and awkward selection on the live simulator. Subsequently user confirmed Paste works in Beakr on the physical iPhone. Physical-device build/OS and exact paste route were not independently verified. These observations do not establish a general iOS editor defect or prove a simulator clipboard root cause.

Automated investigation was confined to Beakr-R1-Contract-Baseline-20261026 (E40CDB24-C697-4F57-8F87-CBFD9DFADDD5). Because it has no networks, a temporary simulator-only debug entry point exposed the existing IOSMessageComposerView using an unconfigured messaging service. No networks created/joined and no messages sent. Native menu Select All -> Cut emptied PASTECHECK; native Paste restored the exact text. Hierarchy showed one TextView; selection handles/menu behaved normally. Local paste PASS in this isolated check; live Pro/Pro Max failure and Mac-to-simulator clipboard transfer remain unreproduced/unresolved. No production editor fix justified by this evidence.

Temporary harness removed from both source files, clean baseline BuildProject passed (BuildProject-Log-20261102-214610.txt), temporary process terminated, clean app reinstalled only on isolated baseline without reset or launch, and Xcode destination restored to Beakr / My Mac. git diff --check passed before this documentation append. All pre-existing workspace/staging changes preserved. Final UI screenshot/hierarchy evidence: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/71E02FA0-5E81-47C6-97E6-A5C2D87448E2/DeviceInteractionSynthesize/Beakr Paste Harness Four-21_52_42_165-screenshot.png and corresponding -hierarchy.txt.

E2 scoped recovery passes stand; strict unknown-member rejection and full R1 signoff remain open. Return Mac, Pro and Pro Max from R1-E2-Test to their existing XYZ selections remains pending user confirmation. Preserve test profiles/history. iPhone 18 Pro untouched.


### E2 return to XYZ — user-confirmed complete, November 2, 2026

User confirmed completion of returning Mac, iPhone 17 Pro and iPhone 17 Pro Max to their existing XYZ networks after the paste investigation. E2 cleanup is complete by user report; test networks/history retained as instructed, iPhone 17 already on XYZ, and iPhone 18 Pro untouched. No additional messaging or connectivity test inferred from this confirmation. Scoped E2 recovery results stand; strict unknown-member rejection, unresolved live-simulator paste behavior and full R1 signoff remain open. No reset, staging or commit performed.


### Disconnected network presentation correction — November 2, 2026

User supplied physical-iPhone screenshot on cellular with no Wi-Fi/Ethernet: selected XYZ displayed Local network unavailable with neutral network/gear and a misleading green local-device dot. User requested wording No Beakr network detected and orange network status, with neutral local-device status. Implemented for inactive connectivity: both network color mappings now orange, iOS/Mac network headers use the requested localized wording, and iOS overview local-device rows require the existing connectivity online rule (readyNoPeers/connected), excluding startup. Moved that existing presentation helper to ActiveNetworkConnectivity so member detail also uses it rather than treating ready membership alone as online. Saved inactive profiles remain neutral; permission/failure states remain red. No membership, routing, or messaging behavior changed.

Xcode BuildProject passed for isolated baseline simulator destination (BuildProject-Log-20261102-221612.txt) and My Mac (BuildProject-Log-20261102-221722.txt). String catalog updated by build; git diff --check passed. Destination restored My Mac. No app launch/install, simulator interaction or device changes; physical-iPhone visual acceptance pending installation of updated build. XYZ restoration remains user-confirmed; iPhone 18 Pro untouched. Existing workspace/staging preserved; no reset/stage/commit.


### Physical-iPhone connectivity presentation — scoped PASS, November 2, 2026

Mac Network Link Conditioner OFF verified from user screenshot at 22:23. User reports conditioner has never run on iPhone-Dev to their knowledge; physical-device OFF state was not independently inspected. Xcode Beakr / 360-iPhone-Dev BuildProject passed (BuildProject-Log-20261102-222404.txt). User then confirmed updated app installed and expected disconnected wording/colours displayed. This supersedes the preceding pending-installation note for this change.

Connected overview screenshot supplied at 22:27 shows Wi-Fi, green settings/network indicators, XYZ, green local iPhone-Dev dot and 2 Devices Online, matching local device plus iPhone-17. User explicitly confirmed recovery without Refresh; exact recovery latency and absence of relaunch were not separately confirmed. MacMini-Ice-9 and Pro/Pro Max appear offline in this screenshot, so no Mac authority availability or all-peer recovery is inferred. Local-device detail screenshot supplied at 22:30 shows green Online and XYZ membership. Record scoped user-observed disconnected presentation and screenshot-supported connected overview/detail PASS. No new messaging, authority-outage, E2 unknown-member rejection or full R1 acceptance claimed.

Toolbar/title overlap remains a separate unresolved layout issue; live-simulator paste issue and full R1 signoff remain open. Existing XYZ identities and test profiles/history retained; no assistant live app interactions, simulator resets, membership changes, staging or commits. iPhone 18 Pro untouched. Xcode last verified on Beakr / 360-iPhone-Dev; no destination switch performed. Documentation appended only for this result.


### E8 approved-before-install interruption — FAIL, November 3, 2026

User activated existing R1-E8-Test on Mac and joined from the previously empty isolated baseline simulator E40CDB24-C697-4F57-8F87-CBFD9DFADDD5. Other participating simulators remained on XYZ. Initial E13 first-create instructions for this iOS simulator were invalid: product network creation requires macOS. No E13 creation occurred; that variant remains NOT RUN.

Baseline debugger PID 72589 was verified by its exact simulator executable path. Breakpoint 1.1 stopped in JoiningEnrollmentCoordinator.complete at line 381, immediately before membershipInstaller.installMembership. Frame inspection showed phase installingMembership, node 3583230D-67AA-5304-BDBB-591430C428D9, network C1C3928F-DC59-4C83-AE81-9A3B529A6DC8, request 3EF46E53-4791-47C5-814C-05A1C8D4950F, transaction 17B37B9C-27AA-4C23-9C0B-09F5783C6D40 (joinNetwork). Source saves the staged approval and installing lifecycle checkpoint before this call. Test breakpoint deleted before requested Stop/Run, without continuing the paused installation.

Following the instructed stop/relaunch, screenshot at 19:15 shows baseline R1-E8-Test red with Setup needs attention; Mac alone online on the test network and baseline member listed offline. Xcode launch 7b58fd4180, PID 74271, logs at 19:15:15 show profile 3FA417C7-3757-456B-B945-1E3C535D1B61 loaded, identity restored, configuration load begun, then starting -> needsConfiguration and startup return after approximately 0.294 seconds. Record FAIL for automatic recovery at this specific pre-install checkpoint, not an enrollment success. No post-recovery messaging pass.

Source lead: start() falls back to resumePendingReleaseEnrollment when configuration is absent; that helper accepts only phase joining and returns false for installingMembership. The saved phase observed at the breakpoint therefore bypasses installation recovery and falls through to needsConfiguration. Fix/regression/retest pending; preserve the same request and profile for recovery. No Refresh, re-import, deletion or revocation requested. Mac remains on R1-E8-Test pending this investigation, and must return to existing XYZ after completion. iPhone 18 Pro untouched; existing workspace/staging preserved, no reset/stage/commit. This run does not repeat or invalidate earlier scoped E8 pending-recovery/repeated-import passes. Conditioner OFF was requested for preparation but not newly confirmed in this exchange.


### E8 pre-install startup recovery fix — November 3, 2026

Fixed NodeBootstrapModel.resumePendingReleaseEnrollment to recognize installingMembership as well as joining when startup finds no configuration. The installing branch uses JoiningEnrollmentCoordinator.resumeMembershipInstallation to verify/replay the existing staged approval and transaction locally, then the existing activation/trust path and durable confirmation flush. It does not create another request or identity. Cancellation/selected-profile guard precedes activation. Existing joining polling remains unchanged.

Extended coldStartReplaysStagedReleaseApproval with component and application-startup variants. Fixtures use disposable profile IDs, keychain identities, configuration and runtime files; the test deletes its identity afterward. Before the product fix, direct resume passed and application startup failed at needsConfiguration with no installed membership/configuration, reproducing the live symptom. After the fix both variants passed, checking ready state for app startup, stable node/profile IDs, persisted member phase, credential and signed membership contents. Trust/LAN dependencies are test fixtures, so this is not live enrollment or radio acceptance.

Xcode BuildProject(buildForTesting: true) passed for baseline destination (final log BuildProject-Log-20261103-191957.txt); RunSomeTests passed 2/2 parameter variants. Xcode ran hosted tests in its managed XCTestDevices clone of the selected baseline (57886A37-A1A7-4ABD-86FA-94F4AAA56459); no live XYZ simulator was selected. Pre-fix result bundle Test-Beakr-2026.11.03_19-18-55--0500.xcresult and post-fix Test-Beakr-2026.11.03_19-19-57--0500.xcresult are under ActionArtifacts/415A8659-CDFD-4F04-A816-4EA3C39CE385/RunSomeTests. My Mac BuildProject passed (BuildProject-Log-20261103-192028.txt), build only; destination restored Beakr-R1-Contract-Baseline-20261026.

Original failed baseline request recovery remains pending user Run of updated app, with Mac still hosting R1-E8-Test. No new invitation, re-import, Refresh, reset, profile deletion or membership revocation needed. Keep the original E8 FAIL and prior scoped passes. No full R1 acceptance claimed. iPhone 18 Pro untouched; workspace/staging preserved, no stage/commit. Next: user Run baseline, observe automatic completion of this same saved request, then verify registration and message exchange before restoring Mac to existing XYZ.


### E8 interrupted-install recovery retest — scoped PASS, November 3, 2026

After running the fixed build on the original isolated baseline simulator, user reported green on startup. This recovered the saved interrupted R1-E8-Test enrollment without a replacement invitation/request. Screenshot supplied at 19:24 shows Mac and baseline each with 2 Devices Online; Device Registration History contains one Beakr-R1-Contract-Baseline-20261026 Registered entry with matching node 3583230D…428D9, alongside the preserved prior test members. The screenshot also shows the original approved request 3EF46E53-4791-47C5-814C-05A1C8D4950F.

User then reported pass for the requested baseline-to-Mac E8-Recovery-1 and Mac reply E8-Recovery-Reply-1 check, including single receipt and both Outboxes clearing without Refresh/resend. Labels reflect the requested procedure; no independent message-ID audit or measured recovery latency was obtained. Record scoped PASS for recovery from the debugger-confirmed saved installingMembership checkpoint immediately before installer entry, registration convergence and post-recovery messaging. This does not prove interruption at every internal installer step or exactly-once installer execution. Preserve the original FAIL and regression/fix evidence; full R1 signoff remains open.

Cleanup next, not yet confirmed: return only Mac Beakr to its existing XYZ selection. Keep R1-E8-Test and R1-E2-Test histories/memberships. Baseline now has an R1-E8-Test membership and must no longer be described as an empty installation; retain it without deleting/resetting. Other live devices remain on existing XYZ by prior report. iPhone 18 Pro untouched. Documentation only for this result; no source/device changes, staging or commits.


### E8 return to XYZ — user-confirmed complete, November 3, 2026

User confirmed Mac Beakr is back on its existing XYZ network after the interrupted-install recovery retest. Cleanup is complete by user report. Preserve all R1-E8-Test and R1-E2-Test profiles/history, including the baseline simulator's new R1-E8-Test membership; baseline is no longer empty. No additional connectivity or messaging pass is inferred from this confirmation. E8 scoped recovery/registration/messaging PASS stands alongside the original failure and fix evidence. Full R1 signoff remains open. iPhone 18 Pro untouched; documentation only, no staging or commits.


### E2 preparation paused for camera permission recovery — November 3, 2026

For the next explicit unknown-member rejection check, user confirmed physical iPhone-Dev has no visible R1-E8-Test profile. Mac activated existing R1-E8-Test; Mac and baseline were reported online together. User then stopped baseline Beakr before enrolling the phone, to retain its pre-phone membership view. Mac remains on R1-E8-Test and baseline must stay stopped until the controlled E2 outage phase. No phone enrollment/approval is confirmed yet. Other XYZ memberships and iPhone 18 Pro remain untouched.

User reported camera access unavailable after installing iOS 27.2 and requested a Settings recovery action. OS-update causality is not established. Implemented in InvitationScannerView.swift: denied permission shows Camera Access Required with Open Settings using UIApplication.openSettingsURLString; undetermined permission is requested asynchronously when the supported scanner is opened; restricted permission and unsupported/temporarily unavailable scanning have distinct explanations. The sheet rechecks camera authorization when its scene becomes active, and renders the camera scanner only when active and authorized. Existing QR validation and enrollment behavior retained.

Applied SwiftUI specialist environment/localization guidance and consulted Apple documentation. Xcode BuildProject passed for Beakr / 360-iPhone-Dev (BuildProject-Log-20261103-193733.txt); git diff --check passed. Build updates the existing string catalog. No automated app interaction or test launch, to preserve the stopped E2 baseline. Physical installation and Settings-to-scanner recovery verification remain pending user Run. Xcode left on 360-iPhone-Dev. No reset, membership removal, staging or commit; all existing work retained.

Next phase: user Run updated physical-iPhone app, open Scan, verify Open Settings reaches Beakr settings, enable Camera, return and check scanner availability. Do not restart baseline or approve a phone join until this permission check is complete. Then resume the prepared E2 sequence; this camera change and build are not an E2 acceptance pass.


### Camera Settings return loses scanner — observed failure and restoration fix, November 3, 2026

User reported returning from Camera permission settings opened Beakr's first page rather than the scanner's initiating screen. Xcode's physical-phone launch PID 1597 ended with signal 9 around 19:38:49, after backgrounding at 19:38:47. This confirms process termination, not its exact OS cause; it explains loss of in-memory sheet state. Foreground authorization rechecking alone does not restore navigation after a process restart. Do not record full Settings-return recovery PASS from the earlier report.

Added a one-time persisted InvitationScannerReturnRoute before opening system Settings. It stores only navigation IDs (including repair profile/network context), not invitation or credential data; expires after 15 minutes; clears on consumption, failed URL open, in-process return, dismissal or recognition. IOSMailRootView consumes it at launch and presents management with the scanner restored. Existing profile selection and enrollment admission rules are unchanged.

Standalone check extracted the exact production route type into /tmp/Beakr-ScannerReturn-Check.swift, using a disposable UserDefaults suite: context roundtrip, one-time consumption, expired/corrupt-record cleanup and explicit clearing passed. No Beakr app or simulator was launched by this check. Physical-iPhone BuildProject passed after final edits (BuildProject-Log-20261103-194252.txt); git diff --check passed. Physical navigation/camera retest remains pending installation. Xcode remains 360-iPhone-Dev; E2 baseline remains stopped by prior user report, Mac on R1-E8-Test, phone join/approval unconfirmed. No staging/commits or membership changes; iPhone 18 Pro untouched.


### E2 unknown-node admission gate captured — November 3, 2026

User confirmed phone Camera Settings return now restores the intended context; no join had occurred at that confirmation. User subsequently joined physical iPhone-Dev to R1-E8-Test while baseline remained stopped and reported Mac/phone 2 Devices Online. User quit only Mac Beakr; TCP probes to 127.0.0.1:8443 and 192.168.1.157:8443 both returned connection refused. User reopened baseline, Xcode launch 7b590df180 PID 81516, profile 3FA417C7-3757-456B-B945-1E3C535D1B61, runtime start 40E6692F-A9C1-493B-A019-9922D5AD5DC5. Logs show authority membership/revocation connection-refused errors and connection rejection, with early retry intervals approximately 1/2/4/8/16/30 seconds before debugger pauses.

Debugger inspection of the baseline's live ProfileMembershipDirectory showed network C1C3928F-DC59-4C83-AE81-9A3B529A6DC8, generation 10, and five node IDs: 060A42D2-D66C-5C1A-93CD-A8107A05A0A4, 3583230D-67AA-5304-BDBB-591430C428D9 (baseline), 6E62C9C9-1DE9-5EDB-8522-60D743AFB57E, A29ED7E5-8597-5F13-817B-93A6080B7532, F5DF5095-4BA8-56AC-8EB7-F9EB1C46F4FF. Conditional breakpoint in sessionID(for:) captured node ACACD3B6-81A6-54BB-8161-B9A601E9200E; dictionary lookup == nil was explicitly true. Stack led through connectionSessionID and ProfileTrustMaintenanceController into outgoing Bonjour authentication. After continuation, the same Task 448 and connection AD436F73-6A9F-4105-B9B2-12CDED6D3D58 reached ProfileBonjourRuntimeService.swift line 71, the failed session-lookup branch emitting acceptedConnectionRejected and returning false before authenticateAndAdmit. This is explicit unknown advertised-node session-admission rejection, not certificate-key rejection or a named LANHandshakeError. Earlier incoming-resolver breakpoint did not hit; the generic rejection diagnostic is shared across paths.

All diagnostic breakpoints created for this check were deleted and baseline resumed without restart. Debugger pauses affect timing; do not claim normal latency or full retry acceptance from the paused interval. Filtered evidence saved /tmp/Beakr-E2-Unknown-Node-20261103.json. Shell ps identity lookup was denied; no elevated retry or device changes used. Phone's R1-E8-Test node identity still needs user confirmation against E9200E. Mac remains quit; original queued-message outage/recovery check has not yet been performed in this run. No full E2 acceptance yet. All memberships/history preserved, iPhone 18 Pro untouched, no stage/commit.


### E2 unknown-node outage and queued delivery recovery — scoped PASS, November 3, 2026

User confirmed physical iPhone-Dev's R1-E8-Test local Node ID ends E9200E, matching the candidate rejected by the baseline's captured unknown-node admission gate. With Mac Beakr still quit, user sent E2-Unknown-1 from phone to baseline node 30C428D9, confirmed it stayed queued on the phone and was absent from the baseline Inbox. After instructions to reopen existing Mac Beakr on R1-E8-Test while leaving both peers running, user reported proper delivery, then confirmed exactly one Inbox copy and removal from phone Outbox with appearance in Sent Items. User explicitly confirmed no Refresh. No peer restart or resend was reported; these were excluded by the procedure, but not independently instrumented.

Record scoped PASS for the captured unknown advertised-node rejection during authority outage and user-observed queued-message recovery after authority return. This adds the previously missing explicit rejection evidence; it does not establish certificate-key rejection, an independent message-ID/storage audit, measured recovery latency, or a captured post-recovery signed membership generation. Earlier E2 bidirectional recovery results remain intact. Full E2/R1 signoff is not asserted here.

Cleanup pending: return Mac Beakr and physical iPhone-Dev to their existing XYZ memberships; retain all R1-E8-Test and R1-E2-Test profiles/history and baseline membership. iPhone 18 Pro remains untouched. Documentation only; no staging, commits, resets or source changes.


### E2 cleanup — user-confirmed complete, November 3, 2026

User explicitly confirmed XYZ is active again on both Mac Beakr and physical iPhone-Dev. This completes the requested cleanup; no new messaging pass is inferred. Retain R1-E8-Test/R1-E2-Test profiles/history and baseline membership. iPhone 18 Pro untouched. E2 scoped outage/rejection/recovery result stands; full R1 signoff remains open. Documentation only, with all existing workspace/staging preserved; no reset, stage or commit.


### R1 acceptance reconciliation — November 3, 2026

Added a current reconciliation at the top of Packages/BeakrNet/Documentation/R1-Signoff-Audit-2026-11-01.md, retaining the original audit as historical. Supersedes stale pending claims for scoped E8 repeated-import/install-checkpoint recovery, E7 queued sender-switch, E6 idle resource/count evidence, E11 configured delay/loss/outage observations, and E2 explicit outgoing unknown-node rejection plus one-copy queued recovery. Does not create new passes or waive remaining criteria. Final build/install inventory, E2 live verified-refresh evidence, E9 live presented-old-credential evidence, independent-authority product work and explicit acceptance dispositions remain open; toolbar overlap and live-simulator Paste remain separately unresolved.

User has no spare Mac or separate macOS test account. E13 clean Mac first-create and failure UI/runtime variants remain NOT RUN in this phase; earlier normal creation and isolated component passes stand. No permission to clear production profiles, create an account or modify product isolation is inferred. Next proposed phase is defining previously requested independent-authority lifecycle/participation behavior before implementation. No device action needed for the reconciliation. Documentation only; original failures and all existing workspace/staging changes retained, no reset/stage/commit. iPhone 18 Pro untouched.


### Independent-authority behavior specification — November 3, 2026

Prepared Packages/BeakrNet/Documentation/Independent-Authority-Hosting-Specification-2026-11-03.md after reviewing recorded design goals and current source. Proposes separate per-authority hosting intent/lifecycle and explicit network-scoped administration while retaining one active messaging network. Switching messaging must preserve enabled authority services; app quit stops in-process hosting. Historical authorities are not all automatically enabled. These are proposed implementation rules, not new tested behavior.

Source confirms selected localAuthority ownership and default port 8443. Concurrent historical profiles may conflict; actual saved endpoint inventory not collected. Safe implementation requires authenticated endpoint discovery/compatibility before moving existing ports, with original identity/TLS policy preserved. Conflict reporting without evicting another listener is an intermediate boundary, not full concurrent-hosting acceptance. No endpoint migration, code changes, builds, tests, app/device actions, staging or commits. Existing XYZ memberships/history and iPhone 18 Pro untouched. Next implementation design: authenticated endpoint relocation and legacy-client compatibility, then authority-manager lifecycle integration under the documented acceptance contract.

### Experimental-build compatibility scope — user clarification, November 3, 2026

User explicitly does not require backward compatibility. Updated the independent-authority specification: hosts and participating clients may require the new build; no legacy protocol, fixed-port fallback or mixed-version acceptance work. Authenticated dynamic endpoint discovery remains necessary for concurrent hosting. Preserve existing identities, keys, memberships, queues and history; this clarification does not authorize resets or touching iPhone 18 Pro. Supersedes the preceding legacy-client compatibility requirement. Documentation only; no code/device/staging changes.


### Independent-authority lifecycle foundation — November 3, 2026

Added BeakrNetHost/AuthorityHostingCoordinator.swift and six focused Swift Testing cases in BeakrNetHostTests/AuthorityHostingCoordinatorTests.swift. The generic actor owns separate per-profile service handles, validates immutable network/node bindings, coalesces duplicate starts, serializes replacement/stop, retains superseded starts until drained, isolates failures, bounds registered entries and pending transitions, and permanently closes start admission during shutdown. Caller cancellation does not cancel shared hosting; explicit stop controls it. Start adapters must clean up failures and bound duration. This phase does not implement persistent hosting intent, automatic retry/backoff, real listener/endpoint adapters, admin routing, UI or app lifecycle integration. Beakr still hosts only its active network.

Focused disposable in-memory package tests passed 6/6: independent services/duplicate start, stop during start, serialized replacement without overlapping services, failure recovery/binding rejection, shutdown during start, and capacity limits. Log /tmp/Beakr-Authority-Lifecycle-20261103.log. No network listeners, keys, live storage, or app interactions used by these fixtures. Xcode BuildProject passed Beakr / baseline (BuildProject-Log-20261103-201624.txt) and My Mac (BuildProject-Log-20261103-201649.txt); destination restored to Beakr-R1-Contract-Baseline-20261026. Builds were not installed or launched. XcodeWrite could not insert a package file (directory insertion mode error); apply_patch wrote the new files instead.

Next phase: persisted hosting intent and authenticated dynamic endpoint adapters, then explicit per-network administration and app integration. Full independent-hosting acceptance and R1 signoff remain open. Existing workspace and staged content preserved, no stage/commit/reset; live XYZ memberships, test histories and iPhone 18 Pro untouched.


### Persistent hosting intent and signed endpoint foundation — November 3, 2026

Added AuthorityHostingPreferences in BeakrNetHost: bounded, versioned atomic-file settings with explicit one-time initialization, per-profile/network/node binding, enabled/disabled intent independent of messaging selection, and no in-memory update on persistence failure. Empty initialization stays initialized; only the initially active owned authority is enabled. Callers must verify ownership; this store grants none. No production store has been opened or modified by this new code.

Added AuthorityEndpoint claims, signed record codec, verifier and a domain-separated CredentialAuthority signing entry point. Records bind authority/network/environment, lowercase DNS hostname, nonzero port, generation and bounded validity (default 120s, maximum 300s). Verifier uses the already trusted authority public key, rejects invalid signatures/bindings/expiry/future issuance and generations below a caller-supplied minimum. Decoding is capped at 4096 bytes. Records carry no replacement keys or CA. TLS CA/hostname validation remains required at connection time. This is a signed record foundation, not implemented Bonjour discovery or live port relocation. Durable host generation allocation, client high-water storage and same-generation endpoint conflict handling remain integration work; the verifier alone does not establish those properties.

Validation: 5 new hosting-preference tests, 5 new signed-endpoint tests and 6 lifecycle regression tests passed (16 total). Preferences tests use disposable temporary directories, including deliberate corruption/write failure; endpoint tests use disposable signing keys with no listeners or live storage. Log /tmp/Beakr-Authority-Intent-Endpoint-20261103.log. Xcode BuildProject passed Beakr / baseline (BuildProject-Log-20261103-202102.txt) and My Mac (BuildProject-Log-20261103-202119.txt); destination restored baseline. git diff --check passed. No installation or app launch.

Next phase: durable endpoint generation/verified-cache state and Bonjour advertisement/resolution adapters, followed by per-network administration and app integration. Current app still hosts only its active network. Backward compatibility remains out of scope. No reset/stage/commit command issued; preserve existing index/workspace contents, XYZ identities, all histories and untouched iPhone 18 Pro.


### Durable endpoint tracking and Bonjour adapters — November 3, 2026

Added PersistentAuthorityEndpointPublisher and PersistentAuthorityEndpointCache. Publisher persists a signed record before returning it, retains generation for same-endpoint renewals and advances it on host/port changes with overflow rejection. Cache persists verified evidence before accepting a route, retains high-water evidence across expiry/reopen, rejects lower generations, conflicting same-generation endpoints and older/conflicting publication times. Failed writes preserve prior in-memory state. Persisted records are signature/binding checked even if expired; current-route lookup independently enforces freshness. Stores assume one owner/writer per path; no protection against externally deleting/rolling back trusted local files is claimed.

Added AuthorityEndpointBonjourCodec (_beakr-auth._tcp), a listener advertisement helper and one-shot AuthorityEndpointBonjourBrowser. TXT framing is bounded to 1300 wire bytes with 200-byte Base64 chunks; malformed/extra/missing/oversized fields fail. Service helper requires the actual bound port to match the signed record. Browser inspects at most 32 results by default (configurable up to 128), emits a truncation flag and uses a single buffered event, with no per-result tasks or retained endpoint registry. Parsed records remain untrusted until cache verification; HTTPS CA/hostname validation is still required. Actual publication renewal, dynamic embedded listener binding, browser-to-client lifecycle ownership and app integration remain pending. No LAN discovery/advertisement was started in this phase.

Consulted Apple Network documentation for listener readiness/port, service TXT updates and browser metadata. Initial package compilation failed because the Data-dictionary NWTXTRecord initializer requires a newer deployment target; switched to the existing string-dictionary API without compatibility branches or deployment-target changes. Retest passed 26 focused tests: previous 16 plus six durable endpoint cases and four Bonjour framing/service/cancel-before-start cases. Logs /tmp/Beakr-Authority-Discovery-20261103.log (initial compile failure) and /tmp/Beakr-Authority-Discovery-20261103-retest.log (pass). Disposable keys/files only; no live-profile access or app interactions.

Xcode BuildProject passed baseline (BuildProject-Log-20261103-202707.txt) and My Mac (BuildProject-Log-20261103-202716.txt); destination restored baseline. No installs or launches. Next: integrate dynamic authority listener/renewal and verified endpoint resolution into real host/client services, then per-network administration and application hosting lifecycle. Current app still hosts only its active network; live discovery and independent hosting acceptance remain unproven. Existing workspace/index preserved without reset/stage/commit commands; XYZ/test histories retained and iPhone 18 Pro untouched.

### Embedded listener and verified HTTP routing — November 3, 2026

EmbeddedAuthorityNode now supports an OS-selected port, publishes a durable signed record for the actual ready listener port, and uses that URL in invitations. LAN listeners advertise that record and schedule renewal every 60 seconds; renewal failure withdraws the advertisement. Stop cancels renewal and drains tracked connections; startup has an eight-second listener deadline, connection handling has a fifteen-second socket deadline and a 64-connection admission cap. Generation checks prevent a stopped startup from publishing a late endpoint. These deadlines do not establish a bound on every underlying router operation. macOS embedded PKCS12 imports explicitly use memory-only import.

Added DiscoveredAuthorityHTTPTransport: each request resolves through the existing authenticated persistent cache, rejects unavailable/expired endpoints and non-origin-relative paths, and uses the existing pinned-CA HTTPS transport with hostname validation. No old-build routing fallback was added. Browser-to-cache lifecycle ownership and application wiring remain pending; existing app call sites still select their current authority port and host only the active network.

Validation: 26 focused endpoint/hosting tests plus one opt-in disposable loopback integration test passed (/tmp/Beakr-Authority-Listener-Integration-20261103.log). Expanded integration retest passed (/tmp/Beakr-Authority-Listener-Trust-20261103.log): two authorities bind different ports, each serves its own membership, invitations use the bound port, wrong TLS authority is rejected, stopping one leaves the other available, and the same client works after restart and acceptance of the new signed record. Temporary bundles/identities only; no LAN advertisement or discovery started by tests. Timed renewal, live Bonjour behavior, startup/stop races under load and independent hosting in the application remain unverified.

Xcode BuildProject passed baseline (BuildProject-Log-20261103-203426.txt) and My Mac (BuildProject-Log-20261103-203455.txt); destination restored to Beakr-R1-Contract-Baseline-20261026. No app installation or launch, no live membership/identity changes, and iPhone 18 Pro untouched. No reset/stage/commit commands. Next phase: discovery-to-cache lifecycle and application transport wiring, followed by per-network administration and independent hosting controls. Full R1 signoff remains open.

### Discovery owner lifecycle — November 3, 2026

Added AuthorityEndpointDiscovery, a single-use owner of one Bonjour browser, one serial candidate-verification task and an existing persistent cache. Resolution lazily starts discovery, rechecks cached signature/freshness, waits up to five seconds by default (configurable from zero to thirty seconds), and honors caller cancellation without stopping the shared owner. Invalid/stale/conflicting advertisements cannot replace the route. Unexpected persistence failures fail resolution closed. Stop cancels browsing, drains candidate processing and rejects future resolution even if the persisted record remains fresh; evidence is retained for later owners. Stream termination closes the owner. DiscoveredAuthorityHTTPTransport can now resolve through this lifecycle owner.

Five injected-stream tests passed without starting LAN browsing: invalid advertisement followed by valid evidence, stopped-owner rejection while retaining cache, timeout/caller cancellation, stream termination, persistence failure, and stop/drain behavior (some combined in individual tests). Existing focused tests also passed: initial run 24 Host plus 5 Core tests; the separate opt-in loopback suite was skipped, not rerun or counted as acceptance. Expanded lifecycle suite passed all five cases. Logs: /tmp/Beakr-Authority-Discovery-Lifecycle-20261103.log and /tmp/Beakr-Authority-Discovery-Lifecycle-Failures-20261103.log. The first log contains a nonfatal SwiftPM read-only manifest-cache warning; compilation and tests succeeded.

Xcode BuildProject passed baseline (BuildProject-Log-20261103-204256.txt) and My Mac (BuildProject-Log-20261103-204304.txt); destination restored baseline. Application source wiring remains pending: DevelopmentAuthorityConfiguration.makeTransport still returns the saved-URL transport; ApplicationLANRuntimeManager and enrollment/bootstrap paths need explicit discovery ownership, profile-scoped cache storage, and shutdown. Pre-profile enrollment paths also create transports directly and must retain immutable invitation trust. Info.plist currently declares only _beakrnet._tcp; _beakr-auth._tcp must be declared when enabling application discovery. Do not claim live discovery or independent hosting acceptance.

No installs, app interactions, live network changes, reset/stage/commit commands, or iPhone 18 Pro access. Existing memberships, identities, histories and staging changes preserved. Next phase is application integration of the tested owner, with bounded runtime/enrollment lifetimes and explicit per-network trust/cache binding; independent hosting controls remain subsequent work. Full R1 signoff stays open.

### Application authority clients use discovery — November 3, 2026

Wired all authority HTTP transport construction in Apps/Beakr to signed endpoint discovery: runtime membership/revocation reconciliation, certificate bootstrap, remote invitation administration, invitation join/repair, release-enrollment submission/recovery/cancellation, pending confirmations and initial membership recovery. Each transport captures immutable profile/network/authority/environment/TLS trust. Pre-installation enrollment uses the invitation's trust and the already allocated profile identity. Saved control-plane URLs remain metadata/bootstrap configuration but are no longer an HTTP fallback. Info.plist now declares _beakr-auth._tcp alongside peer discovery.

Added AuthorityDiscoveryHTTPTransport and AuthorityEndpointCacheRegistry. Each HTTP request owns a browser/discovery consumer, requests cancellation and drains the consumer on success or error, and invalidates its ephemeral URLSession. Caller cancellation reaches resolution and the HTTP task. No background per-profile browser remains between requests. The process-wide registry retains at most 64 cache bindings and admits at most eight simultaneous requests, failing explicitly at capacity; it provides one cache actor/writer per standardized path and rejects rebinding a path to another key/network/environment. The application scopes cache files under Application Support/Beakr/AuthorityEndpoints/<profile>/<network>/<authority>. Authority rotation gets a separate authority-key path; no existing state was migrated or deleted. Existing single-writer assumptions exclude other processes/external file rollback.

Discovery wait is capped at five seconds or the configured request timeout, whichever is smaller; HTTP then has its own bounded timeout (default fifteen seconds, runtime reconciliation two seconds). These are sequential limits, so a cold runtime reconciliation can spend up to two seconds discovering plus two seconds in HTTPS. Fresh signed cached routes remain usable while discovery starts; a failed HTTP request is not automatically replayed, because administrative requests may have side effects. Signed cache updates learned during that request are available to subsequent requests. Live port-change convergence remains to be tested.

Validation: 31 focused package tests passed (26 Host + 5 Core), /tmp/Beakr-App-Discovery-20261103.log. Expanded opt-in loopback integration passed, /tmp/Beakr-App-Discovery-Integration-20261103.log: request-scoped discovery delivered the correct network membership, rejected cache rebinding and a wrong TLS CA, and invoked browser cancellation before returning on success and TLS failure. Discovery events were injected; TLS listeners used loopback and disposable bundles, with memory-only identity imports. No LAN browse or live app interaction was performed by these tests. Xcode BuildProject passed baseline (BuildProject-Log-20261103-204619.txt) and My Mac (BuildProject-Log-20261103-204703.txt); restored baseline destination. git diff --check passed.

No installation, profile/membership/identity mutation, simulator reset, or staging/commit command. iPhone 18 Pro untouched. This changes source-level client routing and requires updated advertising authorities when deployed; mixed-version fallback is intentionally absent. The application still hosts only its active authority. Next: integrate persisted independent-hosting intent/coordinator into the Mac application and bind administration to the selected network, then perform controlled baseline/live discovery acceptance with NLC verified OFF. Live Bonjour, independent application hosting, timed renewal and full R1 signoff remain open.

### Persisted hosting controller and Mac adapter — November 3, 2026

Added PersistedAuthorityHostingController, combining saved intent with the existing bounded listener coordinator. First initialization enables only the active owned network. Later reconciliation honors saved intent irrespective of messaging selection; explicit enable/disable persists before starting/stopping. Operations serialize intent writes with listener transitions (maximum sixteen pending operations); shutdown drains accepted operations without clearing enabled intent. A listener-start failure is reported per network while other enabled authorities can still start. Ownership checks precede controls/administration. AuthorityHostingCoordinator.runningHandle(for:) validates immutable profile/network/local-node bindings and returns only a running handle.

SystemAuthoritativeNetworkCreator now exposes makeHostingController(preferencesURL:) backed by real ownership checks, restore and stop. Embedded authorities created/restored/reset by this adapter now use OS-selected ports rather than binding their saved metadata port; signed endpoint discovery from the previous phase supplies client routing. No existing saved URLs, identities or histories were rewritten. The controller factory is not yet called by NodeBootstrapModel: this is the completed controller/adapter boundary, not independent hosting enabled in the application.

Fifteen focused tests passed (six coordinator, five preferences, four controller), /tmp/Beakr-Persisted-Hosting-Tests-20261103.log. New coverage checks independent enabled intent across selection/reopen, isolated startup failure, ownership/binding rejection, stopped-controller rejection and persistence failure before listener start. Disposable files/fake handles only. Xcode BuildProject passed baseline (BuildProject-Log-20261103-205141.txt) and My Mac (BuildProject-Log-20261103-205149.txt), restored baseline destination. No app installs/launches, LAN tests, live membership changes, resets, stage/commit commands or iPhone 18 Pro access.

Remaining integration is explicit: NodeBootstrapModel still uses localAuthority for startup, profile switching, creation cleanup, deletion, reset and administration; those operations must move together to the shared controller before UI hosting controls are enabled. Profile switching must retain other authorities; deletion/reset must stop the target controller entry, and reset must install/restart its replacement through that owner. Settings invitation/history/actions currently depend on the active-network model and need immutable selected-profile routing plus guarded UI result publication. Review authority endpoint publisher persistence during key reset: its current authority-endpoint.json is signed by the old key, so key replacement needs a key-scoped publisher path (preserving the old file) before reset can be considered functional with endpoint publication. No reset was exercised here. Application shutdown must drain the shared controller. Full R1 signoff, live discovery and independent hosting acceptance remain open.

### Mac independent hosting and per-network administration wired — November 3, 2026

NodeBootstrapModel now owns one persisted hosting controller for the application lifetime. Startup restores enabled owned authorities independently; ownership-check/start failure is isolated per profile. Initial migration enables only the saved active owned authority. Profile switching stops/restarts messaging only and preserves hosted authorities. Make Active does not enable a disabled authority. First-network creation initializes preferences then explicitly enables its authority; additional-network creation remains prepared/inactive with hosting disabled. Explicit Start/Stop Hosting persists intent. Application termination drains the controller after stopping messaging. Injected model-test dependencies use disposable hosting preference files.

Mac Network Settings now exposes Authority Running/Stopped/Starting/Stopping/Failed and Start Hosting / Stop Hosting controls. Ownership labels remain independent of running state; authority hosting does not make an inactive network an online messaging peer. Invitation creation, request refresh/decisions and history export/verification accept an explicit profile ID and resolve the matching running authority. Administration snapshots are keyed by profile; settings read the selected network's snapshot, not the active messaging network's data. Generation checks discard stale administration results after hosting changes/reset/deletion. Approval/rejection retains device-owner authentication, captured network identity and request/network checks. Rename addresses the target authority even if inactive for messaging. Active-network member removal retains its explicit active profile/handle guard.

Deletion persists disabled intent and drains the target before storage deletion, then releases its hosting record/coordinator slot. Reset runs through a serialized withStoppedAuthority operation, drains the temporary replacement returned by the existing creator, and restores through the controller only if enabled intent was previously true. A stopped authority stays stopped. These destructive paths were exercised only with injected package callbacks, never against live profiles. Endpoint publisher files are now authority-key-specific (authority-endpoint-<authorityID>.json), preserving predecessor evidence rather than trying to verify it with a replacement key. The real authority-reset/keychain workflow has not been live-tested. Hosting/reset/deletion controls exclude overlapping messaging switches while those model operations are busy.

Validation: 16 focused package hosting tests plus the existing expanded disposable loopback endpoint test passed in /tmp/Beakr-Hosting-Model-Final-Package-20261103.log. Ownership-error isolation was then added and all five controller tests passed again in /tmp/Beakr-Hosting-Ownership-Isolation-20261103.log. Coverage includes independent intent/restart, start and ownership failure isolation, bound administration lookup, persistence failure, drain-before-replacement/deletion and preservation of disabled intent. Loopback testing used disposable certificates and injected discovery, not LAN advertising.

Xcode RunSomeTests ran only on Beakr-R1-Contract-Baseline-20261026 (E40CDB24-C697-4F57-8F87-CBFD9DFADDD5). First run passed five cases (creation success/failure variants, switch after bootstrap failure, stable ownership identity); second run passed five cases (first creation/history updates, creation variants, inactive rename). There are seven distinct cases across those runs. Extended creation tests prove no stop on messaging switch, Make Active does not start disabled hosting, explicit start runs both, administration targets the original network after switching, stopping one preserves the other, and termination drains both. Test summaries: RunSomeTests/702D5CD8-8B33-4FA8-81D2-19D09F371DB5.txt and RunSomeTests/DC70B011-820F-4F29-A91B-9193ED1E3BD9.txt under the current ActionArtifacts directory. Baseline test execution may deploy/launch the test host; this is not a clean-baseline visual acceptance result.

One intermediate Mac build failed on a stale assignment after invitation display became derived per-network state; removed it. Final Xcode BuildProject passed baseline (BuildProject-Log-20261103-210346.txt) and My Mac (BuildProject-Log-20261103-210352.txt); destination restored baseline. git diff --check passed. Apple swiftui-specialist guidance was consulted for model data flow and control labels.

No physical-iPhone installation, Mac app launch for live testing, live revocation/deletion/reset, simulator reset, or reset/stage/commit command. Existing XYZ identities/memberships and R1-E8-Test/R1-E2-Test history retained; iPhone 18 Pro untouched. NLC was not re-verified during these fake/loopback tests. Next phase: verify NLC OFF, then controlled Mac UI and baseline discovery acceptance using the existing test authority; record active messaging and enabled-hosting states before changing them. Do not claim live independent hosting, Bonjour port-change recovery, timed renewal, real reset acceptance or full R1 signoff yet. Toolbar/title overlap and live-simulator Paste remain separate open issues.

### Live verification preparation — November 3, 2026

User confirmed Network Link Conditioner OFF. Read-only inspection of exact baseline E40CDB24-C697-4F57-8F87-CBFD9DFADDD5 found SpringBoard Home, Beakr installed but not foreground (NotRun); session closed without launching/installing/tapping. Mac process-list lookup was unavailable, so no current Mac app state was inferred. Xcode destination changed to My Mac for the user-guided launch. No Mac app launch or hosting change performed. Next user step: quit any existing Mac Beakr instance, run updated Beakr from Xcode, inspect Settings > Networks > XYZ and report active messaging/authority hosting state. No acceptance result yet; baseline may require a normal app launch later. iPhone 18 Pro untouched.

### First Mac visual check: layout failure and authority startup failure — November 3, 2026

User screenshot at 21:09 showed XYZ active for messaging with five devices online, but Authority: Failed. Hosting controls were severely compressed inside the existing action HStack. This is NOT hosting acceptance. Moved hosting controls into a separate full-width Authority Hosting GroupBox; status, buttons and wrapping explanation use separate rows. Added per-profile failure text and startup failure logging because the existing reconciliation discarded status.failure. Current Mac launch 7b5f632880 logs confirm hosting=false and authority membership/revocation refresh unavailable, but do not contain the underlying startup exception. No cause inferred yet.

My Mac BuildProject passed (BuildProject-Log-20261103-211122.txt); layout and failure-reason display require user relaunch/visual verification. Destination remains My Mac for that manual step. No automated Mac interaction, membership changes, reset/staging/commit, or other-device access. Next: user quit/re-run Mac Beakr and provide the XYZ hosting section and failure reason. Existing separate iPhone toolbar/title overlap remains open.

### Mac hosting invalidRecord follow-up — November 3, 2026

User screenshot at 21:12 confirms readable hosting layout and Authority: Failed / invalidRecord. Current Mac console session 7b5900fd80 independently confirms invalidRecord for XYZ profile 9EBC75CA-932A-413D-B0C3-1511180ACBE8. Messaging remains visibly online; hosting acceptance remains open.

Found a publication defect: strict signed endpoint validation requires lowercase DNS names, but the publisher accepted manifest hostnames without canonicalizing. Normalize hostname case before signing and generation comparison; strict signature, shape and TLS checks remain unchanged. Mixed-case publication/renewal/reopen/cache acceptance regression passes, including invalid-hostname rejection. Saved live manifest could not be read due OS permission restriction, so mixed case is a candidate cause of this live failure, not a confirmed diagnosis.

Seven persistent endpoint tests and five signed endpoint tests passed (/tmp/Beakr-Endpoint-Hostname-20261103.log). My Mac Xcode BuildProject passed (BuildProject-Log-20261103-211804.txt); git diff --check passed. User relaunch is pending to determine whether live hosting recovers. No live profile/identity/membership edits, automated Mac interaction, or staging/reset/commit operations; iPhone 18 Pro untouched.

### Mac authority startup recovery observed — November 3, 2026

User screenshot at 21:20 after manual relaunch shows XYZ Authority: Running, Start Hosting disabled, Stop Hosting enabled, no displayed failure, and XYZ messaging with five devices online. Hosting layout remains readable. This establishes live startup recovery after hostname canonicalization; it does not establish concurrent independent hosting, discovery port-change recovery, or full R1 acceptance. No agent device interaction or membership changes. Next phase: inspect R1-E8-Test hosting state while keeping XYZ active for messaging, then explicitly enable test-authority hosting if stopped.

### Two authority hosting states observed — November 3, 2026

User screenshots: 21:22 R1-E8-Test selected in Settings, messaging Not Active, Authority: Stopped; XYZ remains active with five devices online. After user Start Hosting, 21:23 R1-E8-Test shows Authority: Running while messaging stays inactive and XYZ remains active. At 21:25 user selects XYZ and it still shows Authority: Running, five devices online. Scoped UI acceptance: starting the second owned authority did not stop XYZ hosting or switch messaging. This does not yet prove remote discovery/requests to both authorities, stop isolation, or persistence across relaunch. Next: stop only R1-E8-Test hosting and verify XYZ remains running. No membership/profile deletion, identity changes, automated device interaction, or staging/commit/reset. iPhone 18 Pro remains untouched.

### Authority stop isolation observed — November 3, 2026

User screenshot at 21:26 shows R1-E8-Test Authority: Stopped following explicit Stop Hosting. At 21:27, XYZ still shows Authority: Running and five devices online. Scoped live UI stop-isolation check passed: stopping the test authority did not stop XYZ hosting or change active messaging. Current intended hosting state: XYZ enabled/running, R1-E8-Test disabled/stopped. Next check is persistence of these distinct choices across a normal Mac app quit/relaunch. Remote discovery, concurrent requests, and full R1 signoff remain unproven by these screenshots. No agent device interactions or membership changes.

### Hosting preference persistence observed — November 3, 2026

After instructed normal Mac quit/relaunch, user screenshots at 21:29 and 21:30 show XYZ Authority: Running with five devices online and R1-E8-Test Authority: Stopped, respectively, without pressing Start/Stop after relaunch. Scoped hosting preference persistence check passed for enabled active XYZ and explicitly disabled inactive R1-E8-Test. Remote discovery and administration of an inactive hosted network remain to be verified; full R1 acceptance stays open. Next phase: explicitly start R1-E8-Test hosting while leaving XYZ active, then inspect Invitations for the selected test network. No agent device interactions, membership changes, staging/reset/commit.

### Invitation generation for inactive hosted network — November 3, 2026

At 21:32 user screenshot shows R1-E8-Test selected, Authority: Running, Invitations pane available, with XYZ still active for messaging. At 21:33, after Generate Invitation, a QR code and expiration countdown appear in the selected test-network pane; user explicitly reports no error. Scoped UI generation check passed while the hosted network is inactive for messaging. Invitation payload identity, remote discovery/enrollment, and selection isolation are not established by the screenshot alone. No scan/join requested or performed in this phase. Next: select XYZ's Invitations pane without generating anything and check that the R1-E8-Test invitation does not appear there. Existing profiles/history preserved; iPhone 18 Pro untouched.

### Invitation display isolation observed — November 3, 2026

At 21:35 XYZ Invitations showed no QR code after generating an invitation for inactive hosted R1-E8-Test. On returning to R1-E8-Test at 21:37, its QR/countdown returned with the unchanged 21:48:03 expiration (10:45 remaining). Scoped UI invitation display isolation/retention passed. XYZ remained active for messaging with five devices online. Both authorities were last observed running; no new invitation generation or joining required for this check. Payload identity and remote discovery remain separate pending checks. Next: open Beakr on the designated contract baseline only and inspect its current networks before deciding the discovery test steps. No resets, profile deletion, staging or commits; iPhone 18 Pro untouched.

### Both enabled authorities resume after Mac relaunch — November 3, 2026

Following the instructed normal Mac app quit/reopen, user screenshots at 21:48 show XYZ Authority: Running and R1-E8-Test Authority: Running without Start Hosting. XYZ remains active for messaging with five devices online; R1-E8-Test is inactive for Mac messaging. Scoped enabled-authority persistence check passed for both networks, including the inactive one.

Baseline was manually updated/launched by user at approximately 21:41 and retained R1-E8-Test. Its 21:46 Settings screenshot shows active membership, local device online, zero other messaging devices online, five known devices offline. The displayed ICE-9.local:8443 is saved authority metadata, not proof of the discovered runtime endpoint. Console tool returned Mac session 7b4138ab80 rather than baseline: it contains R1-E8-Test credential-revocations and profile-membership requests at 21:41 and the baseline node discovery afterward. This is server-side request evidence only; client acceptance and discovery after the latest restart remain unverified. No rejoin or profile reset needed. Full R1 signoff remains open; all existing memberships/history preserved and iPhone 18 Pro untouched.

### Baseline client refresh after authority restart — November 3, 2026

User restarted the updated contract baseline through Xcode and reported ready. Current iOS console session 7b59565380 (PID 12901), profile 3FA417C7-3757-456B-B945-1E3C535D1B61, at 21:52:09–21:52:10 shows startup cached membership retained (removed=false), revocations persisted then activated with failedConsumers=0, and membership refresh completed unchanged. This supplies client-side successful trust-refresh evidence after the Mac authority restart, alongside the user's prior R1-E8-Test baseline screenshot and Mac screenshots showing both authorities running while XYZ remains active for messaging. No invitation import or rejoin was needed. Actual old/new bound port values have not been compared, so do not claim measured port-change recovery. Full R1 signoff remains open. No app code, live memberships, devices, staging or commits changed by this log inspection.

### Independent hosting session cleanup — November 3, 2026

User confirmed completion of the requested cleanup: stop only R1-E8-Test hosting, leave XYZ hosting running, retain baseline R1-E8-Test membership. Final hosting state is user-confirmed, not independently re-inspected: XYZ enabled/running, R1-E8-Test disabled/stopped. XYZ remains the intended Mac messaging network. Existing profiles, identities and history retained; iPhone 18 Pro untouched.

This session established scoped UI start/stop isolation, persistence of enabled/disabled hosting choices, automatic restart of two enabled authorities, inactive-network invitation generation and display isolation, and successful baseline client trust refresh after authority restart. Actual before/after listener ports, live discovery port-change recovery, and full R1 signoff remain open. No further live actions requested during cleanup.

### Port-change discovery check prepared — November 3, 2026

Read-only inspection limited to the designated baseline simulator found its persisted signed endpoint cache for profile 3FA417C7-3757-456B-B945-1E3C535D1B61 / R1-E8-Test network C1C3928F-DC59-4C83-AE81-9A3B529A6DC8. Before restarting test-authority hosting, cached claims are hostname ice-9.local, port 49955, generation 3, authority 6373A338-0C10-57E9-BE0B-F367445F00C0, issuedAtMilliseconds 1793760714977, expiresAtMilliseconds 1793760834977. Record is historical evidence, not an assertion of a currently valid route. No signature re-verification performed by the inspection script; prior successful client refresh is separately recorded.

R1-E8-Test hosting is currently user-confirmed stopped. Next: user start only that authority while keeping XYZ messaging active, then restart baseline app to trigger discovery/refresh; compare new persisted endpoint claims and client refresh outcomes. OS port reuse is possible: only claim a port-change pass if a different port is observed. No data mutation or device interaction performed during preparation.

### Measured authority port-change recovery passed — November 3, 2026

After user started R1-E8-Test hosting again and restarted only the baseline app, read-only inspection of the same baseline endpoint cache shows ice-9.local port 49957, generation 4 (previously port 49955, generation 3). Network C1C3928F-DC59-4C83-AE81-9A3B529A6DC8 and authority 6373A338-0C10-57E9-BE0B-F367445F00C0 are unchanged. New claims issuedAtMilliseconds 1793761447949, expiresAtMilliseconds 1793761567949.

Current baseline iOS console session 7b58954f00, PID 15295, at 22:04:38–22:04:39 confirms cached membership retained (removed=false), revocations persisted and activated with failedConsumers=0, and membership refresh unchanged for profile 3FA417C7-3757-456B-B945-1E3C535D1B61. Scoped live port-change recovery on client restart passed: updated persisted endpoint plus successful client trust refresh, without rejoining, identity changes, or replacing the saved network. This does not establish uninterrupted in-process recovery without client restart or full R1 signoff.

Next cleanup: user stop only R1-E8-Test hosting, keep XYZ hosting/messaging running and retain baseline membership. Cleanup pending. No automated app interactions, reset, staging or commit performed; iPhone 18 Pro untouched.

### Port-change check cleanup confirmed — November 3, 2026

User confirmed completion of requested cleanup after measured port-change recovery: R1-E8-Test hosting stopped, XYZ hosting/messaging left running, baseline membership preserved. Final state is user-confirmed, not independently re-inspected. Scoped port-change recovery on client restart passed (49955/generation 3 to 49957/generation 4 with successful trust refresh). Recovery without restarting the client remains untested; full R1 signoff remains open. No further live actions performed.

### In-process manual refresh did not recover — November 3, 2026

User initially uncertain whether refreshing Settings/Networks, then confirmed pull-to-refresh on main baseline Networks screen. Current session 7b58954f00 PID 15295 remains running (same process as before). At 22:17:59 logs show manual-refresh and a new runtime trust-refresh; at 22:18:03 both revocations and membership fail with reason unavailable. Baseline endpoint cache remains port 49957 / generation 4, issuedAtMilliseconds 1793761447949, expiresAtMilliseconds 1793761567949 (expired at refresh time). No new endpoint accepted. In-process manual-refresh recovery is NOT passed. User had been instructed to start R1-E8-Test hosting while keeping XYZ active, but current Mac hosting state has not yet been independently shown. Next: inspect Mac R1-E8-Test Authority Hosting state before attributing failure to discovery or making code changes. Do not restart baseline; preserve same process for diagnosis. No membership changes or device interaction by agent.


### Port-change recovery with manual refresh and no app restart passed — November 3, 2026

User screenshot at 22:26 shows Mac R1-E8-Test Authority: Stopped while XYZ remains active for messaging. User then explicitly started R1-E8-Test hosting and reported Running without errors, followed by a main Networks pull-to-refresh on the designated baseline. The earlier unavailable result does not establish a discovery defect; hosting was subsequently observed stopped, though its exact state at the earlier refresh was not independently captured.

Xcode GetConsoleOutput explicitly queried baseline iOS session 7b58954f00, still running as PID 15295. At 22:28:41 manual-refresh triggered trust refresh; revocations persisted and activated with failedConsumers=0, and membership completed unchanged. Read-only inspection limited to baseline E40CDB24-C697-4F57-8F87-CBFD9DFADDD5 found the same profile/network/authority cache updated from ice-9.local:49957 generation 4 to ice-9.local:49958 generation 5, issuedAtMilliseconds 1793762905520, expiresAtMilliseconds 1793763025520. Profile 3FA417C7-3757-456B-B945-1E3C535D1B61, network C1C3928F-DC59-4C83-AE81-9A3B529A6DC8 and authority 6373A338-0C10-57E9-BE0B-F367445F00C0 remain unchanged. Inspection did not independently re-verify the signature; successful application trust refresh is separate evidence.

Scoped acceptance passed: measured port-change recovery via manual refresh without restarting the baseline app, importing an invitation or rejoining. This does not establish automatic recovery without manual refresh, uninterrupted messaging-runtime continuity, or full R1 signoff. Current last-reported Mac state: R1-E8-Test hosting running, XYZ active for messaging. No cleanup performed yet. No agent app interactions, builds, membership changes, profile deletion, simulator resets, staging or commits; iPhone 18 Pro untouched.


### In-process port-change check cleanup confirmed — November 3, 2026

User confirmed cleanup: stopped only Mac R1-E8-Test hosting, left XYZ hosting/messaging running, and preserved the baseline R1-E8-Test membership. Final hosting state is user-confirmed, not independently re-inspected. Measured port-change recovery with manual refresh and without baseline app restart passed (49957/generation 4 to 49958/generation 5; same PID 15295; revocations activated with zero failed consumers and membership unchanged). Automatic recovery without manual refresh and full R1 signoff remain open. No further live actions performed. Existing identities, profiles/history and staging preserved; iPhone 18 Pro untouched.


### Scheduled automatic authority port-change recovery passed — November 5, 2026

User reconfirmed Network Link Conditioner OFF. Mac screenshots at 16:27 showed XYZ authority Running with XYZ selected for messaging, and R1-E8-Test authority Stopped. User started only R1-E8-Test hosting and confirmed Running, then launched the existing contract baseline with its retained R1-E8-Test membership. No invitation import or rejoin.

Xcode GetConsoleOutput verified baseline iOS session 77a14f9980, PID 13694, using senderImagePath under simulator E40CDB24-C697-4F57-8F87-CBFD9DFADDD5. Profile 3FA417C7-3757-456B-B945-1E3C535D1B61 completed startup revocation and membership refresh unchanged at 16:30:06. Read-only endpoint cache inspection recorded ice-9.local port 49967 / generation 6 for network C1C3928F-DC59-4C83-AE81-9A3B529A6DC8 and authority 6373A338-0C10-57E9-BE0B-F367445F00C0.

User then stopped/started only R1-E8-Test hosting and confirmed Running before the 16:31:30 inspection. Baseline remained open without requested Refresh/restart. At 16:31:30 the same PID/session retained the old endpoint, with the next scheduled trust refresh due at 16:45:06. The observation was explicitly scoped to that scheduled refresh rather than the usual 60-second recovery window.

Inspection at 19:42 Toronto time found the same baseline session/PID still running. At 16:45:06.647 scheduled revocation refresh began; at 16:45:06.802 revocations activated with failedConsumers=0; scheduled membership refresh completed unchanged at 16:45:06.875. Subsequent scheduled refreshes continued successfully through 19:30:17. No manual-refresh or foreground trigger appeared in the queried session logs. The endpoint cache now contains ice-9.local port 49968 / generation 7 with the same network/authority binding; latest claims issuedAtMilliseconds 1793925003127, expiresAtMilliseconds 1793925123127. The later cache read does not establish the exact instant the new endpoint was first persisted. Inspection did not independently verify the cache signature; successful application trust refresh is separate evidence.

Scoped PASS: automatic authority port-change recovery through scheduled maintenance without baseline app restart or manual Refresh. This does not establish recovery within 60 seconds, continuous message delivery during the change, or full R1 signoff. No code changes, builds, automated app interactions, identity/membership changes, reset, staging or commit. iPhone 18 Pro untouched. Cleanup pending: stop only R1-E8-Test hosting, retain baseline membership, and leave XYZ hosting/messaging running.


### Scheduled port-change check cleanup confirmed — November 5, 2026

User confirmed completion of the requested cleanup: stopped only R1-E8-Test authority hosting, left XYZ authority hosting and messaging running, and retained the baseline R1-E8-Test membership. This is user-confirmed state, not a fresh independent inspection. Scheduled automatic port-change recovery is recorded as a scoped PASS in the preceding entry; do not repeat it without a specific regression reason. Full R1 signoff remains open. Next phase is current-build visual inspection of the unresolved physical-iPhone toolbar/title overlap, using user-supplied evidence only. No automated physical-device interaction, code/build changes, resets, staging or commits.


### Physical-iPhone stale trust failure and authority renewal fix — November 5, 2026

During the toolbar/title visual check, user installed/ran Beakr on 360-iPhone-Dev. iOS first displayed Untrusted Developer; this platform app-signing trust is distinct from Beakr network trust. After launch, the 19:49 root screenshot shows no toolbar/title overlap in that captured state, but XYZ Connection failed. Do not claim every navigation/layout state accepted. User screenshots show saved-trust-expired Last Error, Local Network permission ON, Mac XYZ Authority Running, and the matching phone node E8C3C596-8478-52E4-8577-FF194EC8C0B3 still listed as Member on Mac. No identity replacement or rejoin performed.

Read-only physical-iOS console session 77a1443900, PID 4955, profile 8DD518C6-CF16-41E3-9138-173540E8DF96 shows startup cached membership removed=false, then LANHandshakeError code 13 during certificate/revocation restoration. Repeated foreground attempts and the user-requested manual Refresh at 19:57:00 failed similarly. Last Error confirms stale revocation information. The Members section incorrectly classified any non-ready active profile as revoked; failed Refresh also automatically displayed Current Invitation Required. Neither proves actual revocation or a need to rejoin. The relationship to the iOS signing-trust prompt remains unestablished.

Found a concrete server freshness gap: AuthorityTrustStateCoordinator renewed revocations at authority startup/trust mutations, but RevocationSnapshotHTTPEndpoint could serve an aging unchanged snapshot indefinitely. Added coordinator-backed request-time renewal once the signed snapshot is at least one hour old. Valid GETs obtain one immutable snapshot from the coordinator before conditional ETag evaluation; renewal signs the existing revocation set, durably persists it, and preserves membership. Invalid requests do not renew. Persistence failure returns 503 instead of stale success/304. Client admission freshness, signatures, rollback checks and membership permissions are unchanged. The coordinator installs durable ledger changes before endpoint awaits so renewal cannot overwrite an in-flight membership installation. Provider ownership is weak; no new periodic tasks.

ContentView now gives generic setup/Last Error guidance in the Members section instead of asserting revocation from non-ready state. Removed the automatic invitation dialog after failed reconnect/activation; the explicitly chosen invitation menu remains available. No automatic profile repair or invitation import was added. SwiftUI specialist localization guidance was consulted.

Validation: all 16 focused package test functions passed (AuthorityTrustStateCoordinatorTests, RevocationNetworkTests, RevocationRefreshTests; parameterized cases additional). Three new tests exercise a 25-hour idle authority conditional GET with retained revoked credentials and surviving membership, signature/freshness validation, persistence/reopen, subsequent 304, twelve concurrent requests, invalid request rejection and failed durable renewal. Log: /tmp/Beakr-R1-Trust-Freshness-20261105.log. SwiftPM required execution outside the command sandbox after nested sandbox failure. Xcode BuildProject passed final baseline iOS (BuildProject-Log-20261105-200601.txt) and My Mac (BuildProject-Log-20261105-200607.txt). git diff --check passed.

Live root cause remains a supported explanation rather than server-response-confirmed proof; the current phone recovery has not been retested with the updated authority. No agent app launches, physical-device interaction, membership revocation, profile deletion, simulator reset, staging or commits. All pre-existing workspace/index changes preserved; iPhone 18 Pro untouched. Xcode destination is My Mac for the next user-driven phase: quit/re-run Mac Beakr, verify XYZ authority Running and XYZ messaging selected, leave R1-E8-Test hosting stopped. Preserve the existing physical-phone profile and app session before the subsequent single Refresh recovery check. Mac restart itself refreshes the snapshot, so a live recovery afterward does not independently prove long-idle request-time renewal; the isolated clock-controlled regression covers that behavior. R1 signoff remains open.


### Phone trust recovery observed; peer churn remains — November 5, 2026

User ran the updated Mac build and confirmed XYZ authority Running, XYZ selected for messaging, R1-E8-Test authority Stopped. User kept the existing physical-phone app and reported recovery after the requested single Refresh, but observed Devices rows updating intermittently (estimated one per 15 seconds). This is not complete messaging acceptance.

Explicit Xcode session inspection: physical iOS session 77a1443900 / PID 4955 remained running. Successful trust startup appears at 20:10:30 (before the explicit manual-refresh trace at 20:11:47); both that startup and the post-manual-refresh startup completed revocation/membership refresh unchanged. Thus recovery should not be attributed solely to the manual Refresh. Mac restart renews the snapshot independently of the new request-time behavior. No phone reinstallation, rejoin or identity change was required for this observed recovery.

Physical phone logs show recurring authenticating then connectionClosed events and rapid peer-count changes: at 20:14:56.281 count rose to 2, then at 20:14:56.328 dropped to 1; at 20:15:25.220 rose to 2 then at 20:15:25.269 dropped to 1. Current Mac session 779ae3c000 / PID 49451 (macOS image path verified) shows similar short-lived count 1-to-2-to-1 transitions and recurring transport closures. This supports real connection churn rather than merely a slow Devices UI refresh; individual affected peer identities and causes remain to correlate. Green status alone is not all-peer or delivery acceptance.

User described pasted C1200-series certificate failures as My Mac output. Explicit session checks instead associate matching C1212-C1217 errors and simulator boringssl paths with baseline iOS session 77a14f9980 / PID 13694. Baseline is on R1-E8-Test, other active peers on XYZ; wrong-network discovery attempts are a candidate explanation, not proven from certificate errors alone. The real Mac also logs separate certificate failures (for example C81 at 20:15:16, /usr/lib/libboringssl.dylib). Do not collapse baseline TLS failures, Mac TLS failures and phone connection churn into one established cause.

No new code changes, builds, device interactions, revocations, profile changes, staging or commits in this observation phase. Next: identify the member rows that oscillate and correlate those identities with admission/closure events before requesting more lifecycle actions. Preserve iPhone 18 Pro untouched and all existing history. Full R1 signoff remains open.


### XYZ simulator handshake rejection identified — November 5, 2026, approximately 20:40

User explicitly requested no UI fix; investigation remained read-only for applications. Physical iPhone shows simulator peers briefly green then grey. iPhone 17 simulator was mapped by device metadata and process path to DE26C44E-C798-4645-B26C-FF891A09F71F / PID 98298. Its own unified logs report repeated transport authenticationFailed(reason: "staleRevocationSnapshot"). At 20:39:20.001 the simulator reports this rejection; the physical phone session 77a1443900 / PID 4955 reports connectionClosed at 20:39:20.009851, consistent with the observed brief authentication/presence followed by closure. These timestamps support correlation, not a shared connection UUID across endpoints.

Simulator trust-refresh logs at 20:06:58, 20:21:59, and 20:37:00 show both revocations and membership requests failing with NSURLErrorDomain -1004 / connection refused at https://ice-9.local:8443. This is actual failing request evidence, not merely the saved endpoint displayed in UI. The running Mac PID 49451 listens on ports 49969 and 49970, not 8443. Physical-phone requests appear at Mac local port 49969.

The installed Beakr.debug.dylib modification timestamp is November 1, 2026 21:44:17 for all three XYZ simulators (iPhone 17, iPhone 17 Pro, iPhone 17 Pro Max), predating November 3 dynamic authority endpoint discovery. This supports outdated simulator builds as the cause of continued attempts at the old authority endpoint. A current-build recovery comparison is still required; no fresh discovery defect or full R1 pass is claimed. Other two simulators' individual rejection reasons were not independently captured in this phase.

Next user-driven phase: build/run the current Beakr over the existing installation on iPhone 17 only, preserving its data and XYZ membership; observe stable Mac/physical-phone connectivity before updating other simulators. Agent automation remains limited to the designated baseline. No reinstall by deletion, rejoin, trust bypass, UI change, or simulator reset. Existing workspace/staging preserved.


### Current iPhone 17 build restores Mac/physical-phone connections — November 5, 2026

After the user updated only iPhone 17 over its existing installation, its process is PID 55337 on simulator DE26C44E-C798-4645-B26C-FF891A09F71F (bundle container AAE29290-B0FB-4BBC-AD65-2FD67760163C). Read-only simulator logs show successful startup revocation and membership checks (unchanged) at 20:43:47. The existing node F12D8774-7350-5FBA-9125-690477546629 authenticated with Mac at 20:43:50 and physical iPhone-Dev at 20:43:51. No closure for these connections was found in the queried logs through the observation window ending approximately 20:44:22. Mac session 779ae3c000 / PID 49451 connection 1AFB5328-7C21-4369-B3B1-9150F09A9C64 and physical iOS session 77a1443900 / PID 4955 connection 0EDB1C14-7D43-4521-AE8B-3199F8F3E81C independently show authentication without a recorded closure. Xcode's default console query again returned Mac logs, so simulator startup evidence was obtained from its explicitly scoped unified log.

The updated simulator still sees immediate closures from iPhone 17 Pro and Pro Max, which remain on the older builds. This is scoped recovery evidence for updating iPhone 17, not full-network or message-delivery acceptance. No UI changes, agent builds, automated app interactions, or membership changes. Next user-driven phase: update iPhone 17 Pro only, preserving its existing app data, then verify its connections before updating Pro Max.


### Updated iPhone 17 Pro recovery — November 5, 2026, 21:13

User updated iPhone 17 Pro over the existing installation. Read-only process mapping verifies simulator 8A655C12-31F0-4AFD-967B-F8DB8E92AC05 / PID 59846, bundle container 5506DD3F-8380-432C-BFF2-371984DF7E06. Its scoped unified log shows startup revocation and membership checks succeeded unchanged at 21:12:28. Existing node 66D45727-F322-5C23-86CA-8CCC1540AA67 authenticated with physical iPhone-Dev at 21:12:28 and Mac at 21:12:29; no closures for those connections appear through 21:13:32. Independently verified physical session 77a1443900 / PID 4955 connection D041D154-8531-4E94-926C-74B4A724C19A and Mac session 779ae3c000 / PID 49451 connection 7B2B3521-4FDF-4D7F-B9FC-DEDA0C173769 show authentication with no recorded closure. Pro Max connections still close immediately. No iPhone 17-to-Pro connection result is claimed from this capture.

Scoped recovery only; full mesh stability and message delivery remain unverified. No UI or application code changes, builds, automated app interactions, membership changes, or staging changes by agent. Next phase: user builds/runs current Beakr over existing iPhone 17 Pro Max installation, preserving data and membership.


### Updated Pro Max recovery; concurrent-device check pending — November 5, 2026

User completed Pro Max update. Read-only process mapping: simulator 45367EFE-5644-45C6-9150-D0160C579819 / PID 60503 / bundle container BBB67161-58C6-46F7-A1FE-21BEB7E5113F. Startup revocations and membership succeeded unchanged at 21:16:08. Existing node 35A51E3A-B2DB-58D8-AEB0-1C5D6780317B authenticated with physical iPhone-Dev at 21:16:08 and Mac at 21:16:09; no closure appears in the captured logs. Physical session 77a1443900 / PID 4955 connection 0AEDEBC0-5C55-4AA6-AF70-D74A83865FC9 and Mac session 779ae3c000 / PID 49451 connection 671A1E9A-B036-4FA4-8F79-D66E86EC4CC0 confirm authentication without recorded closure.

Process inspection now finds only Pro Max running among the three XYZ simulators; iPhone 17 and 17 Pro are not running. Do not claim simultaneous recovery or complete connectivity. Next user phase: open already-installed Beakr directly on iPhone 17 and 17 Pro, leaving Pro Max running, then inspect concurrent membership presence. No agent UI/app-state changes, resets, rejoining, builds, staging, or commits. Waveform/status explanation proposal remains deferred UI design discussion.


### Concurrent XYZ recovery observed before phone backgrounding — November 5, 2026

User opened updated iPhone 17 and 17 Pro directly. Read-only process mapping confirms all three simulators running: iPhone 17 PID 61162, Pro PID 61163, Pro Max PID 60503. iPhone 17 scoped logs show authenticated links to Mac, Pro Max, physical iPhone-Dev, and Pro by 21:19:59. Physical phone session 77a1443900 / PID 4955 reached four authenticated peers at 21:19:59; Mac session 779ae3c000 / PID 49451 reached four at 21:20:02. This supports concurrent five-device recovery, but is not a sustained-stability or message-delivery pass.

At 21:20:12 the physical phone logged application-inactive; at 21:20:14 it logged application-background, advanced runtime generation 6 -> 7, transitioned connected(peerCount: 4) -> inactive, and closed all four connections. Thus these simultaneous closures coincide with explicit background lifecycle handling, not the earlier repeated stale-trust rejection. Do not classify them as recurrence of that defect. Next phase: user returns Beakr on physical iPhone-Dev to the foreground and keeps it visible for an observation interval. No UI/app code or runtime changes by agent; no staging/commits.


### Stable XYZ presence and message round trip — November 5, 2026 — scoped PASS

After all three XYZ simulators were updated in place and reopened together, user returned Beakr on physical iPhone-Dev to the foreground for the requested 60-second observation and reported "solid green." This records user-confirmed stable simulator presence following the earlier grey/green flicker; no UI workaround was applied.

User then reported "pass" for the requested XYZ round trip: iPhone-Dev sends to iPhone 17 with subject R1-Updated-Peers-1, and iPhone 17 replies, with both apps foregrounded. Record successful delivery in both directions as user-confirmed evidence; message IDs, latency, duplicate counts, and delivery to every other peer were not independently measured. This closes the scoped updated-peer recovery/delivery check, not full R1 acceptance or all-pairs messaging coverage.

Existing XYZ identities/memberships and history were preserved; no rejoin, deletion, reset, live revocation, or UI change was required for this recovery. Earlier automatic endpoint recovery and other passed checks remain valid within their recorded scope. Full R1 signoff remains open. No agent staging or commits.


### Live iPhone 17 native Cut/Paste — November 5, 2026 — scoped PASS

User exercised the updated iPhone 17 simulator's New Message composer (not the originally suggested Pro Reply composer). Command-A reportedly selected only the current word. Screenshots at 21:32–21:33 show selected text plus overlapping spelling/suggestion presentation; this does not establish two independent editor selections. Using the native editing menu, Cut emptied the entire body by explicit user confirmation. Native Paste then restored the text once; user confirmed "Yes" and the 21:36:57 screenshot shows R1-paste-checks in the body.

Record native local Cut/Paste PASS for this live New Message composer. No message send or draft cancellation confirmed in this phase. Command-A behavior, Mac-to-simulator clipboard transfer, and the originally reported Reply-specific path remain outside this pass. No product UI fix, automated app interaction, build, profile/membership change, staging, or commit performed. Next bounded check: host-copied plain text pasted through the iOS editing menu in the same disposable draft.


### Mac-to-live-simulator Paste and shortcut disposition — November 5, 2026

User copied text from the Mac chat window into the unsent iPhone 17 New Message editor: Command-V did not insert it, while the native long-press Paste menu did. Record user-confirmed host-to-simulator clipboard transfer/native Paste PASS for this composer, alongside the preceding local Cut/Paste pass. User also reported select/copy/paste in a message to Mac and its return to iPhone 17. This does not independently establish the originally suggested Pro Reply path.

User agreed to track Command-A/Command-V as a separate simulator keyboard-shortcut issue, outside R1 networking; cause remains unassigned between Device Hub, platform input routing and application handling. No UI fix requested or made. Draft cancellation has not been explicitly confirmed. Next bounded visual check is the still-open physical-iPhone toolbar/title overlap in the current build; root screenshots alone do not cover scrolled message/detail transitions. Full R1 signoff remains open.


### Physical-iPhone root overlap reproduced; narrow correction — November 5, 2026

User screenshot at 21:52 on physical iPhone-Dev shows the scrolled Beakr title behind the status bar and Networks behind the gear/waveform control. User requested return-to-top on returning to the first page, then explicitly authorized the fix. Earlier no-UI-change instruction is superseded only for this narrow correction; waveform/status redesign remains deferred.

Apps/Beakr/ContentView.swift now gives the iOS root navigation bar an explicitly visible systemGroupedBackground, removes the root title row's negative top padding, and uses ScrollViewReader with a stable title target to return to the top on root appearance/back-navigation. Existing disclosure state is retained; peer/member updates do not trigger scroll resets. Navigation destinations, messages, trust, and hosting behavior are unchanged by this edit.

Xcode BuildProject passed for Beakr-R1-Contract-Baseline-20261026: BuildProject-Log-20261105-215825.txt. git diff --check passed. Runtime baseline verification underway; physical-device acceptance remains pending. No staging or commits; all pre-existing workspace/index changes preserved.


### Root toolbar correction — baseline verification and phone build — November 5, 2026

Device-interaction skill verification was confined to baseline E40CDB24-C697-4F57-8F87-CBFD9DFADDD5, updated in place, PID 68527. Expanded Members/Mailboxes, scrolled to bottom, opened existing Inbox (two preserved unread messages; neither opened), and returned. Toolbar/status-bar background concealed scrolling text; no visible lettering behind controls/time. Back returned to fully readable Beakr/Networks title with both disclosures retained. Scroll-to-title aligns title at toolbar bottom (y116 versus initial y151), so this is return-to-title rather than restoration of identical initial inset/absolute offset. No observed overlap. Light appearance and baseline normal text size only; physical dark/large-text reproduction remains pending.

Evidence directory: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7F7C57AE-8063-486A-9ACD-B1936787648D/DeviceInteractionSynthesize/
Screenshots/hierarchies: Verify Root Toolbar And Return-22_05_00_889 (initial), -22_07_03_796 (scrolled), -22_08_33_056 (Inbox), -22_09_39_982 (return). Interaction session closed. No other device app actions, hosting/membership changes, sending/deletion/reset/rejoin.

Xcode BuildProject also passed 360-iPhone-Dev: BuildProject-Log-20261105-221305.txt. Xcode left on 360-iPhone-Dev for user Run; agent did not install/launch/interact on physical phone. Next: user Run current build over existing installation, repeat root scroll -> Inbox/message -> back navigation on phone, verify titles/controls stay separate. No staging or commits; full R1 visual acceptance remains pending that confirmation.


### Friendly-name update leaves connectivity monitoring stopped — November 5, 2026

User reports renaming simulator/physical device friendly names, initial name propagation with green XYZ, then orange on Pro, Pro Max and physical phone; foregrounding phone recovers. Screenshots at 22:00 show Mac and iPhone 17 listing five online including devices whose own display is orange. This must not be assumed equivalent to the earlier old-build stale-trust rejection.

Read-only iPhone 17 Pro unified logs (simulator 8A655C12-31F0-4AFD-967B-F8DB8E92AC05, PID 61163) record connected(peerCount: 4) -> inactive at 21:57:32.285, before the baseline layout verification installation. Historical physical Xcode session 77a1443900 is no longer available; no current physical log claims inferred.

Source diagnosis: NodeBootstrapModel.applyDeviceFriendlyName calls stopObservingAuthenticatedPeers and stopObservingLocalNetwork; the latter sets hasUsableLocalNetwork=false and cancels permission/availability observers. It restarts lanRuntimeManager and peer observation but never probes localNetworkAvailable or restarts beginObservingLocalNetwork. applyAuthenticatedPeerIDs then clears onlineMemberIDs and assigns inactive while hasUsableLocalNetwork remains false. Normal startLANRuntime probes availability and restores both observers, consistent with user-observed foreground recovery. This is a concrete rename-path defect; exact rename timestamp and delay were not captured, so do not assert the user's estimated delay is a measured timer.

Agent layout changes were confined to ContentView root presentation/scrolling, deployed only on baseline; physical build was build-only. No automated app interactions on XYZ participants occurred in this investigation. No new source fix made in this diagnostic phase. Preserve Pro's current state; next correction should restore rename lifecycle monitoring, not mask its connectivity display. Physical layout acceptance remains pending; the supplied screenshots predate the 22:13 physical build and cannot certify it.


## E14 — repeatable Friendly Name change regression (November 5)

Status (November 7): COMPLETE within the user-approved scope. Physical-iPhone, Mac and original iPhone 17 simulator foreground variants and physical-iPhone near-background/foreground variant passed. User accepted the passing isolated inactive-save/startup regression for the unavailable live-UI variant, retaining that limitation. Earlier November 5 failure/fix evidence remains recorded; this is not full R1 signoff.

1. Record app builds, OS, current Network Link Conditioner state, authority-hosting state, messaging network ID, node/profile IDs, and original friendly names. Use the same intended build on participating devices. Preserve XYZ and existing test memberships/history; never touch iPhone 18 Pro. Agent interactions remain restricted to the contract baseline simulator.
2. With at least two connected remote peers, record each device's member list and send a uniquely labelled E14 message in both directions. Change only one device's Friendly Name to a unique temporary name. Record save time and any brief restart/recovery interval.
3. Verify the new name appears on all peers for the SAME node ID, with no duplicate member. Within the usual 60-second recovery window, verify connectivity from both the renamed device and its peers. Do not infer success from the network colour alone.
4. Keep the renamed app foreground for five minutes after recovery. Capture member lists at recovery and at one, three, and five minutes; record any disagreement, flicker, orange state, retries, or failures. Do not Refresh, relaunch, or background/foreground to rescue this run. Send and verify one copy of uniquely labelled messages both ways after the observation period.
5. Restore the original Friendly Name and repeat the recovery/observation checks. Confirm node/profile/network IDs, membership and existing message history are unchanged. Repeat separately for Mac, physical iPhone (user-operated), and simulator. A pass on one platform does not certify the others.
6. Separate variants: save a name while messaging is inactive and verify it is advertised at the next normal startup; repeat a rename near a normal background/foreground transition and record timing. Keep these results separate from the uninterrupted foreground case. Any intervention needed for recovery is recorded as a failure before diagnosis.

Record each execution as E14/<date>/<platform>/<variant>, with original/temporary/restored names, action and recovery timestamps, build identity, observed peer counts, message IDs/outcomes, and diagnostics. Re-run after changes to name advertisement, runtime restart/lifecycle handling, or path/peer observation.


### Final root reset verification and builds — November 5, 2026

Corrected List presentation reset: scoped baseline PASS, PID 75123. Initial and post-Inbox-return title positions match exactly (Beakr y151, Networks y213.5, AX scroll 0%). Before opening Inbox the root was scrolled to 100%. Members/Mailboxes disclosures remained expanded. Opaque toolbar continued to prevent visible overlap. Inbox stayed at two unread; no messages opened/sent/deleted. Interaction session closed. Physical dark/large-text check is still user-driven and pending.

Evidence directory: /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/7F7C57AE-8063-486A-9ACD-B1936787648D/DeviceInteractionSynthesize/
Capture stems: Verify Native Top Reset-22_42_20_871 (initial expanded), -22_43_23_130 (scrolled), -22_43_52_791 (Inbox), -22_44_24_353 (returned exact top).

Xcode BuildProject passes: baseline BuildProject-Log-20261105-223854.txt; My Mac BuildProject-Log-20261105-224606.txt; 360-iPhone-Dev BuildProject-Log-20261105-224615.txt. Xcode left on 360-iPhone-Dev. Mac/physical builds were build-only; user must Run over the existing installation to deploy. Baseline received in-place app update only. No other device automation, hosting/membership changes, resets, staging or commits. git diff --check passed.

Next phase: user Run on physical iPhone-Dev and confirm scroll -> Inbox -> Back restores the true top without manual adjustment. Then perform newly documented E14 Friendly Name acceptance one platform at a time on matching builds. E14 live acceptance and full R1 signoff remain open; fixture regressions passed 2/2 as recorded above.


### Physical root reset PASS; unified local-device detail — November 5, 2026

User explicitly reported "pass - scroll test" on physical iPhone-Dev after the corrected build. Record scoped physical return-to-top acceptance alongside the baseline exact-spacing pass; this does not certify Friendly Name E14 or full R1.

User supplied two local-device detail screenshots and requested one consistent page with discoverable Friendly Name editing. ContentView now routes a local Members entry to the same IOSDeviceSettingsView used by This Device settings, retaining the preferred This Device layout and visible name/pencil button. The shared page retains the selected network's Node ID and membership context, including inactive networks, without substituting the active network's ID. Removed the duplicate hidden long-press name editor from the peer-detail page; remote peers remain read-only. No network/identity/hosting mutations are introduced by navigation.

Xcode BuildProject passed for 360-iPhone-Dev: BuildProject-Log-20261105-230253.txt. git diff --check passed. No automated device interactions or installs in this phase, no staging/commits. Xcode remains on 360-iPhone-Dev for user Run over the existing installation. Next visual check: open this device via Members and via settings; both should show the same layout and visible Friendly Name pencil. E14 live rename acceptance remains pending.


## E15 — saved membership versus presence (November 6)

Status (reconciled November 7): PASS within the documented manual/fixture scope; see “E15 acceptance complete within documented scope” below for evidence and limits. E14 Friendly Name acceptance and full R1 signoff remain open.

1. Record builds, current messaging network, authority-hosting states, and current Network Link Conditioner state. Keep XYZ selected during the initial inspection. Never use iPhone 18 Pro; agent app interaction remains baseline-only.
2. On Mac, expand Members under an existing inactive network with previously enrolled peers. Its non-online category should read UnObserved and show members from that network's saved snapshot. Record names/Node IDs and any saved-membership notice. Missing/invalid snapshots must explicitly report unavailable, rather than implying that only the local device belongs. Expired records must be labelled as needing refresh. Do not rejoin or generate memberships to fill the view.
3. Open This Device details and compare the saved-network inventory and per-network local Node IDs with existing profiles. The selected messaging network is marked. On iPhone, inspect the same sections through Members and settings; preserved history remains separate from saved memberships.
4. In a separately agreed switch phase, choose an existing test messaging network and return. Confirm its own member list and Node IDs appear, saved members remain visible when it becomes inactive, and no XYZ online status or remote-peer IP is borrowed for an inactive-network member. The known local-device IPv4 address may remain visible while its inactive-network presence stays UnObserved. Record actual authority-hosting states before/after and confirm no hosting changes were caused by viewing lists.
5. Confirm messages/history and membership identities remain unchanged. Viewing an inactive list must not invoke enrollment, trust repair, member removal, or start another messaging runtime. Do not run destructive stale/corrupt-file variants on live profiles; these are fixture-only.

Automated supporting evidence: savedMembershipPresentation and memberRevocationPresentation passed (2/2) on the contract baseline. Coverage includes network mismatch, invalid signature, missing snapshot, expiry, verified revocation exclusion, placeholder/address behavior and unchanged snapshot bytes. This does not establish live roster completeness or multi-network presence monitoring.


### Provisional presence label — UnObserved — November 6, 2026

User chose exact spelling UnObserved in place of Presence unknown. Updated application headings, member labels, saved-membership notices and accessibility labels. Scope: this node's observation of this network with the current software capabilities; it does not imply offline or deliberately hidden. E15's earlier Presence unknown references now mean UnObserved. The supplied Mac screenshot supports saved Hamilton member display (four devices) while XYZ remains selected; it is not a full E15 pass.

Recorded future authenticated multi-network presence observation, independent of messaging/UI selection and authority hosting, in Independent-Authority-Hosting-Specification-2026-11-03.md. No concurrent network runtime behavior changed in this label patch.


### November 6 saved-membership acceptance reconciled — November 7, 2026

Evidence source: user's resume report, including the explicit “pass” at 23:42 November 6. These are historical user-operated observations, not new agent device checks.

- Mac: Hamilton Members showed four saved members under UnObserved while XYZ remained selected for messaging. Local details listed all eight saved networks with distinct per-network Node IDs; Hamilton's top Node ID matched its membership entry, and only XYZ said Used for messaging. Remote iPhone - Dev details showed Hamilton membership only, UnObserved, historical last-seen and unknown IPs.
- Physical iPhone-Dev, friendly name iPhone-Dev-T1: user ran current source; This Device showed saved networks and per-network Node IDs. Hamilton node 7AEB96D6-1076-55EC-85CB-F6B266FF7E5D matched the Mac's saved record. XYZ node E8C3C596-8478-52E4-8577-FF194EC8C0B3 matched the top of This Device and XYZ said Used for messaging. Hamilton Members showed four saved members as UnObserved while XYZ stayed selected.
- Late correction in Apps/Beakr/ContentView.swift: removed the ordinary “Saved membership · UnObserved” notice from the iOS root Members list, retained stale/unavailable notices, supplied the known local IPv4 address to the local row regardless of messaging selection, retained UnObserved for inactive presence and unknown IPs for remote inactive members, and limited the empty live-discovery message to the active network.
- Historical validation: Xcode BuildProject for 360-iPhone-Dev passed (BuildProject-Log-20261106-234027.txt); git diff --check passed. User ran the updated build and explicitly reported “pass” at 23:42. Supplied screenshot showed XYZ selected/green with two devices online, Hamilton inactive, local UnObserved with populated IP and remote IP unknown. No new build or retest is implied by this reconciliation.

E15 disposition: scoped saved-member list and local/remote detail checks PASS on the observed platforms. Full E15 remains OPEN: procedure step 4 network-switch/return isolation and step 5 identity/history preservation across that phase are not established by these screenshots. The settings-versus-Members entry-route equivalence and actual hosting-state comparisons are not independently certified by this report. Missing/invalid/expired snapshot variants retain their existing fixture evidence; do not corrupt live profiles. The known local IP is a local-device fact, not proof of live participation in an inactive network; remote inactive IPs remain unknown. UnObserved means this app instance is not currently observing that member on that network, not globally offline. Expired saved data remains presentation-only.

Next single phase: prepare E15 network-switch/return isolation on one user-operated participant, then agree the existing test profile before switching. First reconfirm Network Link Conditioner (last confirmed OFF November 5), Mac XYZ hosting/messaging and R1-E8-Test hosting (last cleanup: XYZ running, E8 stopped), and the participant's current selection/build. Record before/after hosting, per-network Node IDs, membership and history; do not repeat the passed static Hamilton screenshots. No switch or hosting change is performed or inferred by this entry.

E14 remains OPEN: corrected runtime restart and regression tests do not replace live rename propagation, timed observation, bidirectional delivery and original-name restoration. Other R1 boundaries remain explicit: E1/E3 freshness/refresh traces; E2 post-recovery verified generation/admission; E6 repeated-cycle resource limits and E11 timing/retry telemetry dispositions; E9 live old-credential rejection limits with no live revocation authorized; E13 unavailable clean-Mac/failure UI variants; and final source/build/install inventory. No blanket waiver or full R1 signoff.

Preserve all workspace and staging changes, XYZ identities/memberships and R1-E8-Test/R1-E2-Test history. Never touch iPhone 18 Pro. Agent app interactions remain limited to baseline E40CDB24-C697-4F57-8F87-CBFD9DFADDD5; Mac, physical iPhone and other simulators are user-operated. Verify console platform/session/PID before using logs; old session identifiers are historical only. Last recorded Xcode destination is 360-iPhone-Dev, not freshly verified. This reconciliation changes documentation only; no reset, staging, commit, app interaction or live profile mutation.


### E15 preparation: E8 hosting confirmation — November 7, 2026

User explicitly confirms “R1-E8-Test's Authority is not running.” Record user-observed stopped/not-running hosting for R1-E8-Test (C1C3928F-DC59-4C83-AE81-9A3B529A6DC8); no agent hosting action or independent runtime measurement occurred. Current Network Link Conditioner, Mac XYZ hosting/messaging and physical-iPhone selection still require confirmation before the E15 switch/return phase. No new E15 pass is claimed.

User also requested recording a minor feature to show hosting status through the Networks list authority icon, potentially slashed for Stopped. Recorded in Next-Milestones.md under “Minor feature request: authority hosting status in Networks”; implementation is deferred and is not an added R1 acceptance gate. Documentation only; workspace/staging, identities, memberships and history preserved.


### E15 preparation: Network Link Conditioner confirmed OFF — November 7, 2026

User replied “Off” to the current Network Link Conditioner confirmation. Record Network Link Conditioner OFF for this preparation phase, superseding the November 5 last-confirmed date. R1-E8-Test authority remains last user-confirmed not running. Mac XYZ hosting/messaging and physical-iPhone XYZ selection have not yet been reconfirmed in this phase. No live test, network switch, app interaction or new acceptance pass occurred; documentation only.


### E15 preparation: XYZ state confirmed — November 7, 2026

User replied “Yes, Yes” to confirmation that Mac XYZ authority hosting is running with XYZ selected for messaging, and physical iPhone has XYZ selected. Together with the preceding confirmations, current preparation state is Network Link Conditioner OFF, R1-E8-Test authority not running, Mac XYZ hosting/messaging running, and physical iPhone XYZ selected. These are user confirmations, not independently collected console evidence. No switch/return acceptance pass is claimed.

Next bounded user-operated step: on physical iPhone only, select the existing R1-E8-Test profile for messaging, leaving Mac on XYZ and hosting states unchanged. Inspect that test network's member list and local Node ID, and verify inactive XYZ is UnObserved with remote IPs unknown (known local IP may remain visible). Do not start E8 hosting, re-enroll, Refresh to repair trust, or modify memberships/history. If activation is blocked, record the result and stop rather than repairing the profile. Return-to-XYZ and preservation checks follow after this observation; the overall E15 phase remains open.


### E15 switch attempt: E8 Connection failed — November 7, 2026

On the user-operated physical iPhone, user checked Use Messaging for existing R1-E8-Test and reported that it became red with “Connection failed.” E8 authority was confirmed not running before this attempt; Network Link Conditioner was confirmed OFF, and Mac remained last confirmed hosting/messaging XYZ. This records an unsuccessful activation observation, not a successful E15 switch/return check. The cause is unestablished: authority unavailability, saved-trust freshness or another startup failure must not be inferred from the colour/summary alone. No detailed error, current console platform/session/PID, E8 local Node ID or inactive XYZ isolation observation has yet been captured. Return to XYZ is not yet confirmed.

Next bounded step is user read-only inspection of any displayed Connection failed details; retain the exact wording if available, then guide return to XYZ. Do not start E8 hosting, Refresh, re-enroll, delete profiles or reset devices to rescue this attempt. No agent app interaction, source change, build, staging or commit occurred. Full E15 and R1 remain open.


### E15 E8 activation detail: expired saved trust — November 7, 2026

User supplied screenshot “Pasted 2026-11-07 at 17.30.28.png” (phone clock 5:29), showing R1-E8-Test, Status “Setup Needs Attention”, This Device “Unavailable”, Other Devices Online 0 and Known Devices Offline 0. Last Error reads: “The network’s saved trust information has expired. Keep the authority Mac running and Local Network permission enabled, then retry device setup. Routes remain disabled until fresh signed information is available.” The local iPhone-Dev-T1 row shows Node ID ACACD3B6-81A6-54BB-8161-B9A601E9200E.

This establishes the app's reported expired-trust startup gate while E8 hosting is user-confirmed stopped. It does not independently measure snapshot expiry, prove network-level rejection, establish an empty membership roster, or certify E15 isolation. The previous cause-unestablished entry is superseded only by this displayed diagnostic; no console capture was used. No new regression or required re-enrollment is inferred.

Next single user-operated step: return physical iPhone messaging selection to existing XYZ without Refresh or E8 repair/hosting changes, then report whether XYZ recovers and its local Node ID remains E8C3C596-8478-52E4-8577-FF194EC8C0B3. Return and history/membership preservation are not yet confirmed. E15 successful activation/switch coverage remains incomplete. No source change, device automation, build, staging or commit.


### E15 return from blocked E8 activation: XYZ recovery confirmed — November 7, 2026

User replied “Confirmed” to the requested physical-iPhone return to XYZ and verification that XYZ is green with local Node ID E8C3C596-8478-52E4-8577-FF194EC8C0B3. Record scoped user-confirmed return/recovery with unchanged XYZ local identity after E8 activation was blocked by reported expired saved trust. The requested procedure used Use Messaging without Refresh or E8 repair; no additional intervention was reported. No console trace, delivery test or independent runtime measurement is claimed.

This is not a successful E8 activation or full E15 pass. Remaining checks include existing message/history preservation after the attempted switch, inactive E8 saved-member presentation, before/after hosting-state comparison, and successful switch isolation using valid trust in a separately prepared phase. Do not repeat the already-passed Hamilton static display checks. Next bounded user observation: verify existing XYZ message history remains present and Mac hosting remains XYZ Running / R1-E8-Test Stopped; no hosting changes or new messages requested. No app/source changes, builds, automated device actions, reset, staging or commit.


### E15 blocked-switch return: history and hosting confirmed — November 7, 2026

User replied “Confirmed” to both requested checks: existing XYZ message history remains present on the physical iPhone, and Mac authority hosting remains XYZ Running / R1-E8-Test Stopped. Together with the preceding green XYZ/original Node ID confirmation, this completes the scoped return/preservation check after E8 activation was blocked by expired saved trust. No message-content inventory, complete membership comparison or runtime trace is inferred from this user confirmation.

Full E15 remains open: successful activation of the alternate network and its member/identity/presence isolation were not exercised. Preserve this blocked-activation and successful-return evidence; do not repeat the passed XYZ return/history or Hamilton static display checks without a specific reason. A subsequent successful-switch phase needs an existing network with fresh signed trust. If R1-E8-Test is used, prepare a bounded temporary authority-hosting start and restoration to Stopped with the user before proceeding; do not infer that it has already been enabled. No re-enrollment, profile deletion, reset or live revocation is needed or authorized. Documentation only; no source/build/device/staging changes.


### E15 successful-switch preparation: E8 hosting Running — November 7, 2026

User reports “E8-Test Authority Hosting == Running” after the requested user-operated Mac Start Hosting action for R1-E8-Test. Record E8 authority hosting Running by user observation. The instruction retained Mac XYZ messaging and physical-iPhone XYZ selection; no fresh independent confirmation of those selections or console/runtime capture is inferred. This temporary hosting change prepares fresh signed trust availability; it does not yet prove that the phone refreshed trust or activated E8 successfully.

Next bounded user step: on physical iPhone, select existing R1-E8-Test via Use Messaging once, allowing up to 60 seconds for startup without manual Refresh. Report status and any Last Error; if startup succeeds, record the local Node ID and whether inactive XYZ members remain UnObserved with remote IPs unknown. Green is not required if no other E8 messaging peer is active. Do not re-enroll or repair if it fails. Restore E8 hosting to Stopped after the switch/return phase; cleanup remains pending. Full E15 remains open. No agent app interaction, code change, build, staging or commit.


### E15 E8 selection with authority running: blue and isolated XYZ presence — November 7, 2026

Physical-iPhone user reports R1-E8-Test is Blue after selecting it with E8 authority hosting Running; Node/Device ID ends in 200E; inactive XYZ members are all UnObserved. The suffix is consistent with the previously screenshot-recorded E8 node ACACD3B6-81A6-54BB-8161-B9A601E9200E, but this report does not reverify the entire UUID. Record scoped UI selection/presence evidence, not authenticated peer connectivity, delivery or a verified trust-refresh generation. Remote inactive XYZ IPs were not reported and remain unchecked for this switch.

User corrects the requested procedure: there is no Last Error UI on the iPhone for any network in the current view. Do not require locating that control during normal-state acceptance. The earlier supplied failed-state screenshot did display Last Error; retain it as historical evidence without assuming the control is always available or contradicting the user's current observation.

User also observes XYZ retains all member friendly names, while E8 has three members without remembered friendly names, possibly simulators. Their identities and prior E8 name history have not been established. Names are remembered per network; XYZ metadata alone does not prove E8 previously learned those names. Do not copy names across network identities or label this as expected behavior/a regression without evidence. Next bounded inspection: capture the E8 member list and establish whether those same E8 members had friendly names before this switch; also confirm inactive XYZ remote IPs remain unknown. No UI redesign or source change requested/performed.

E15 remains scoped/incomplete. Physical iPhone is last reported on E8; Mac was instructed to remain messaging XYZ. E8 hosting remains last confirmed Running and must be restored to Stopped after return checks. No agent device interaction, build, staging or commit.


### E15 active E8 member-list screenshot — November 7, 2026, 17:43

User supplied “Pasted 2026-11-07 at 17.43.21.png” (phone clock 5:42). R1-E8-Test is blue with a messaging-selection icon and “1 Device Online”. Six member rows are visible: local iPhone-Dev-T1 with green dot and populated/truncated local IP; Network Device 7A05A0A4; Beakr-R1-Contract-Baseline-20261026; MacMini-Ice-9; Network Device 080B7532; Network Device 1C46F4FF. All five remote rows have grey dots and Device IP: --. Do not reconstruct the truncated local IP from this screenshot.

This confirms the active E8 roster presentation and three fallback names, while the baseline and Mac friendly names are retained. It does not identify the three fallback rows as simulators or establish that previously saved names were lost. No name-persistence regression is yet proven. The image contains E8 only, so inactive XYZ remote-IP isolation remains unverified despite the earlier user confirmation that XYZ members are UnObserved. Next single observation: inspect inactive XYZ remote rows for Device IP: -- while E8 remains selected; no repeat E8 activation or static Hamilton check needed. Return-to-XYZ and restoration of E8 hosting to Stopped remain pending for this successful-activation phase. No source changes, build, agent device interactions, staging or commit.


### E15 inactive XYZ presence/IP isolation — scoped PASS, November 7, 2026

User supplied “Pasted 2026-11-07 at 17.44.53.png” (phone clock 5:44) in the ongoing physical-iPhone E8-selected phase. XYZ is explicitly Inactive. All five visible members show UnObserved: local iPhone-Dev-T1, MacMini-Ice-9, iPhone-17 Pro Max, iPhone-17 Pro and iPhone-17. All four remote rows show Device IP: --. The network header retains known local IP 192.168.1.184; the local member row also retains a populated, truncated local IP. This is consistent with the local-IP exception and does not imply inactive-network presence.

Record scoped PASS for the rendered inactive XYZ presence/remote-IP isolation after E8 selection. This screenshot does not independently show E8 selection, which is established by the preceding observation, nor does it prove transport-level isolation or full E15 completion. Friendly names remain visible for the XYZ members.

Next single user phase: return physical iPhone to XYZ using Use Messaging without Refresh; confirm green recovery and original XYZ Node ID/history, then inspect inactive E8 for retention of its six saved members with UnObserved and unknown remote IPs. This return is required after the successful E8 activation and is distinct from the already-passed return after blocked activation. E8 authority remains last confirmed Running; restoration to Stopped follows the return observation and is still pending. No source/build/agent-device/staging changes.


### E15 return after active E8 selection — scoped observations, November 7, 2026

User reports “yes green” for physical-iPhone return to XYZ. For inactive E8-Test, user confirms members still have the missing friendly names, all are UnObserved, and Device IPs are -- except This Device, which retains the expected local IP. Record scoped PASS for XYZ green recovery and inactive E8 member retention/presence/IP presentation after the successful E8 selection. The earlier active E8 screenshot recorded six members, including three fallback names; this reply does not explicitly recount the roster or reverify full Node IDs. The missing-name observation persists and remains unclassified; do not assert metadata loss or identify those rows as simulators without evidence.

The reply explicitly confirms colour and inactive-member presentation, but does not separately confirm original XYZ Node ID or existing message history after this successful-activation cycle. Earlier identity/history confirmation belongs to the blocked-activation return and is retained as such. Full E15 is not declared complete.

Next bounded cleanup: user stops only R1-E8-Test authority hosting on Mac, leaving XYZ authority hosting Running and messaging selected on XYZ. Confirm those hosting states and the physical iPhone's original XYZ Node ID E8C3C596-8478-52E4-8577-FF194EC8C0B3 and existing XYZ history. E8 hosting restoration remains pending until user confirmation. No agent app actions, code changes, builds, resets, staging or commits.


### E15 cleanup: E8 hosting Stopped; XYZ green — November 7, 2026

User confirms “E8-Test Authority == Stopped” and “iPhone Network XYZ green and has node id ...B3”. Record completion of the temporary E8 hosting cleanup and user-observed green XYZ return. The reported B3 suffix is consistent with the previously established XYZ node E8C3C596-8478-52E4-8577-FF194EC8C0B3; do not represent this abbreviated report as an independent full-UUID capture. Mac XYZ hosting/messaging was instructed to remain running/selected; no new explicit Mac XYZ state confirmation was supplied in this reply.

Existing XYZ message history after this successful E8 activation/return cycle has not yet been explicitly confirmed. Ask only for that remaining user observation; do not repeat the completed hosting cleanup, green-state or inactive presence/IP checks. Earlier history preservation after the blocked E8 activation remains separate evidence. E8's three fallback friendly names remain an unresolved observation, not a proven regression. No full E15 or R1 signoff claimed. Documentation only; no source, build, agent device, staging or commit changes.


### E15 successful-switch cycle: XYZ history confirmed — November 7, 2026

User replied “confirmed” to the specific check that existing XYZ message history remains present on the physical iPhone after the successful E8 activation/return cycle. This closes the pending history observation for this cycle, separately from the earlier blocked-activation return.

Scoped cycle outcome: with E8 authority temporarily Running, physical iPhone selected E8 (blue, one local device online; node suffix 200E), displayed its six-member roster, and showed inactive XYZ members as UnObserved with remote IPs unknown. After return, XYZ was green with node suffix B3 and existing history preserved; inactive E8 retained members with UnObserved, unknown remote IPs and known local IP. User confirmed E8 authority restored to Stopped. Record these user/screenshot observations as a scoped E15 switch/return presentation and XYZ-history PASS, not full-UUID recapture, complete membership/storage comparison, delivery testing or transport-level isolation proof.

Full E15 remains open for reconciliation against its formal procedure, including any unverified entry-route/hosting-state or identity/history requirements. Three E8 fallback friendly names remain an unresolved observation without evidence of previously stored names being lost. Full E14 live Friendly Name acceptance and full R1 also remain open. Do not repeat this completed cycle without a specific reason. Next bounded phase is read-only reconciliation of E15's remaining evidence and E8 name history before choosing further live checks; no device action is required by this entry. Existing constraints and all workspace/staging preserved; documentation only, no build, app interaction, reset, stage or commit.


### E15 evidence and friendly-name review — November 7, 2026

Read-only source/history review; no device interaction or tests repeated. ApplicationLANRuntimeManager.memberSummaries (around lines 546–601) learns/persists a discovered name only for an authenticated member, when remembering previously connected devices is enabled. Metadata is loaded from network-context network-members.json. Active summaries use authenticated names then that context's remembered name, otherwise Network Device plus the last eight UUID characters. SavedNetworkMembershipLoader uses the same context metadata and fallback; signed roster presence alone does not supply a friendly name. Load failures can also yield empty metadata with diagnostics, so source inspection alone cannot establish why a particular name is absent. No physical-phone stored files or console were inspected.

Historical evidence: November 2 identifies A29ED7E5-8597-5F13-817B-93A6080B7532 as the iPhone 17 Pro Max E8 applicant. November 3's five-node baseline roster contains the other two fallback IDs, 060A42D2-D66C-5C1A-93CD-A8107A05A0A4 and F5DF5095-4BA8-56AC-8EB7-F9EB1C46F4FF, but searched notes do not map those two individually to device names. The physical phone joined E8 November 3; documented contacts then establish Mac/baseline participation, not authenticated contact with those three simulators on E8. Thus absence of locally learned names is a supported explanation, not a proven diagnosis. Earlier statements that none of the three could be identified are superseded for 080B7532. No evidence establishes previously stored E8 names were lost on this phone; retain the observation without classifying a regression or creating a new acceptance gate. Do not copy names from XYZ or bring simulators online merely to fill labels.

E15 procedure reconciliation:

| Procedure | Evidence/status |
| --- | --- |
| 1: environment/builds | November 6 build records retained; November 7 conditioner OFF and initial hosting/selection confirmed. Final participant build/install inventory remains a separate R1 item. |
| 2: inactive Mac roster and stale/unavailable handling | November 6 Hamilton display scoped PASS. Missing/invalid/expired snapshots have the previously passed fixture evidence; no destructive live variants required. |
| 3: local identities and detail routes | Mac eight-network and phone saved-membership identity/detail observations passed November 6. Source routes both iPhone local Members and Settings to IOSDeviceSettingsView (ContentView.swift around 4924 and 7453); manual equivalence of both entry routes is not explicitly confirmed. |
| 4: existing-network switch and return | November 7 physical XYZ → E8 → XYZ roster/presence/IP display checks and return PASS within recorded scope. E8 authority start/stop were deliberate preparation/cleanup, not viewing side effects. Initial Mac XYZ Running and E8 final Stopped are recorded; final Mac XYZ hosting state after the successful cycle lacks explicit confirmation. No repeat switch needed. |
| 5: history/identity preservation and read-only viewing | XYZ history and identity continuity confirmed within recorded full-ID/suffix limits; E8 local ID consistent before/after activation. Saved-reader fixture checks preserve snapshot bytes and source shows presentation-only loading. Existing E8 history has not explicitly been checked after this cycle; no entire-store byte audit or new message delivery test is added as a requirement. |

Full E15 remains open only for the stated remaining evidence/disposition, not for repeating scoped passes or demanding exhaustive UUID/storage recapture. Next single user phase: without changing messaging or hosting, confirm final Mac XYZ hosting is Running and inspect existing E8 history from the inactive network to establish it remains present; do not start E8 messaging to do so. If history cannot be viewed inactive, report that rather than switching. The iPhone entry-route equivalence check can follow separately. E14 and full R1 remain open. Three-name observation stays documented and unproven as a defect.

Workspace and staging preserved. No source edits, builds, device actions, membership changes, reset, stage or commit. Documentation reconciliation only; git diff --check passed after edits.


### E15 final hosting and E8 history confirmed — November 7, 2026

User explicitly confirms “XYZ Hosting == running” and “E8's messages are visible” following the requested inspection without changing messaging/hosting. Record Mac XYZ authority Running and existing inactive E8 message history visible. E8 authority remains last explicitly confirmed Stopped; physical iPhone remains last confirmed XYZ selected/green. This closes the final Mac XYZ hosting-state and E8-history evidence gaps identified by the read-only reconciliation. No additional switch, delivery, exhaustive message inventory or runtime trace is inferred.

Remaining explicit E15 manual check: on physical iPhone with XYZ selected, compare local Members → This Device details with Settings → This Device. Both should expose the unified layout/Friendly Name edit affordance, saved-network inventory, per-network local Node IDs and XYZ messaging marker. Inspect only; do not edit the name or switch networks. Earlier scoped display/identity and switch-return passes remain valid and need not be repeated. Full E15 awaits this entry-route observation/reconciliation; E14 and full R1 remain open. Documentation only; no source/build/device automation, staging, commit or profile changes.


### E15 acceptance complete within documented scope — November 7, 2026

User reports “Yes, it appears to be the same page with the same initial values” when comparing physical-iPhone XYZ Members → local device with Settings → This Device, against the requested shared layout, Friendly Name pencil, saved-network inventory/per-network Node IDs and XYZ Used for messaging marker. Record user-observed entry-route equivalence PASS; no name edit or network switch was requested.

E15 disposition: PASS within the documented manual/fixture scope. November 6 Mac and physical-iPhone saved-member/local/remote detail observations, existing signed saved-snapshot fixture checks, November 7 successful XYZ → E8 → XYZ presentation isolation, local identity continuity within recorded full-ID/suffix limits, both networks' existing history visibility, explicit hosting preparation/cleanup and final entry-route equivalence together cover the stated procedure. Do not repeat passed checks without a specific reason. This is not exhaustive storage, all-platform switching, transport-trace or final-build certification. The earlier expired-trust activation block and subsequent authority-available success remain separately recorded.

The three E8 fallback names remain a documented observation, not a proven loss of previously learned names or an additional E15 gate. Source learns names after authenticated per-network contact; historical evidence identifies suffix 080B7532 as iPhone 17 Pro Max but does not show the physical phone had learned that E8 name. No UI/name-copy workaround is warranted by current evidence.

Latest confirmed cleanup: Mac XYZ authority Running, E8 authority Stopped; physical iPhone XYZ selected/green with original-node suffix B3 and existing XYZ/E8 history visible. Network Link Conditioner last confirmed OFF November 7. No new console capture; any later logs require explicit platform/session/PID verification. Preserve all existing identities, memberships and histories; archived iPhone 18 Pro remains untouched.

Next single outstanding phase: E14 physical-iPhone uninterrupted-foreground Friendly Name acceptance. Prepare matching participant builds/OS and at least two connected remote peers before renaming; current last-recorded two total online devices do not establish that prerequisite. Capture original name (last observed iPhone-Dev-T1), identities and environment, then follow the existing E14 procedure for baseline bidirectional messaging, one temporary rename, propagation and recovery, one/three/five-minute observation, post-observation roundtrip and original-name restoration. No device launch, rename or repeat of E15 is authorized/performed by this documentation entry. Platform/lifecycle E14 variants remain separate. Full R1 remains open, including the previously recorded E1/E3, E2, E6/E11, E9, E13 and final build-inventory boundaries.

Documentation only; no source edits, builds, device interactions, resets, staging or commits. Existing workspace and staged content preserved.


### E14 preparation: duplicate iPhone 17 simulator destinations — November 7, 2026, 18:10

User screenshot at 18:08 shows Mac XYZ listing Mac, iPhone-17 and iPhone-Dev-T1 online, while the visible iPhone 17 / iOS 27.2 app displays No Networks. Read-only device/process inspection establishes TWO booted simulators named iPhone 17:
- Existing XYZ participant: DE26C44E-C798-4645-B26C-FF891A09F71F, iOS 27.0, Beakr PID 77544 started 18:05:16, bundle container AAE29290-B0FB-4BBC-AD65-2FD67760163C. Installed Beakr.debug.dylib modification time November 5 20:06:00.
- Screenshot's iOS 27.2 instance: 0B04AF4A-E038-49FE-BE52-E522B4875BC7, Beakr PID 78100 started 18:07:13, bundle container 3C626E7D-F98B-450A-9590-55BFB8074BE8. Installed Beakr.debug.dylib modification time November 7 18:06:36.

Xcode GetConsoleOutput returned Mac, not simulator: launch session 7c7acb7900/PID 37600, explicitly verified macOS sender image path; debugger process status independently matched running PID 37600. Mac logs record authentication of original XYZ simulator node F12D8774-7350-5FBA-9125-690477546629 at 18:05:20. These are Mac-side observations, not simulator startup logs. The two device/process mappings plus screenshot runtime label explain the apparent online/No Networks contradiction. No evidence establishes loss of the original simulator profiles or a startup defect in that original instance. No simulator logs or private profile contents were read.

Initial sandboxed simctl/ps reads were blocked; approved read-only device/process inspection then succeeded. No agent app interaction, launch/stop, attach/pause, install, build, reset, enrollment or deletion occurred. Binary timestamps identify installation age, not a complete source fingerprint.

Next single user action: select the EXISTING iPhone 17 on iOS 27.0, UUID DE26C44E-C798-4645-B26C-FF891A09F71F, and build/run current source over its existing installation. Do not enroll the separate iOS 27.2 instance, copy profiles or delete/reset either simulator. Earlier instruction using only the device name was ambiguous; use runtime and UUID going forward. Reconfirm original XYZ appears before continuing E14. No Friendly Name test has begun. E15 recorded passes stand; full R1 remains open. Documentation updated only; staging preserved.


### E14 preparation: original simulator destination selected — November 7, 2026

User could not see the original iPhone 17 in Xcode/Device Hub. XcodeListRunDestinations explicitly lists iPhone 17 (27.0) as eligible for Beakr alongside active iPhone 17 (27.2). Project deployment target is 27.0; no deployment-setting change required. XcodeSwitchRunDestination successfully selected iPhone 17 (27.0), with returned active scheme Beakr and active destination iPhone 17 (27.0). This changes only Xcode selection; no build, install, app launch/stop or simulator interaction was performed. Device Hub visibility behavior remains unexplained and is not evidence of missing profiles.

Next action remains user Run on the selected original destination, over the existing installation, then confirm its XYZ UI. No enrollment/reset/deletion/migration needed. E14 has not begun; preserve all workspace/staging and live history.


### E14 preparation: original iPhone 17 XYZ UI restored/visible — November 7, 2026, 18:14

User supplied “Screenshot 2026-11-07 at 6.14.57 PM (2).png” after the request to Run on the selected iPhone 17 (27.0). The visible iOS 27.0 simulator now shows XYZ green, 3 Devices Online, and saved Hamilton/R1-E8-Test inactive. Mac simultaneously shows XYZ with MacMini-Ice-9, iPhone-17 and iPhone-Dev-T1 online. Separate iOS 27.2 simulator is visible at its Home Screen. This supports resolution of the wrong-instance UI confusion, not recovery from proven profile loss. No independently captured build result or installed binary fingerprint is added by this screenshot.

Next single E14 step: pre-rename bidirectional XYZ delivery between physical iPhone and original iPhone 17 (27.0), using unique subject E14-Phone-Before-20261107 and a reply. Keep Mac and both participants foregrounded; physical phone should show both remote peers online. Do not rename yet. Original phone friendly name remains last observed iPhone-Dev-T1. The existing E14 timed rename/restore procedure has not begun; no message delivery pass is inferred from online counts. Existing November 7 conditioner OFF and hosting observations remain the latest records. No agent app interactions/builds, source edits, staging or commits.


### E14 physical-iPhone pre-rename roundtrip — user-confirmed PASS, November 7, 2026

User replied “confirmed and foregrounded... all 3” to the requested physical iPhone → original iPhone 17 (iOS 27.0) message E14-Phone-Before-20261107 and simulator reply, with one receipt each. Record scoped user-confirmed pre-rename bidirectional delivery and all three apps foregrounded (Mac, physical phone, original simulator). No independent message IDs or timings captured. This is E14 preparation, not a rename/restore acceptance pass.

Next step: on physical iPhone only, change Friendly Name from last-observed iPhone-Dev-T1 to iPhone-Dev-E14, noting save time and verifying XYZ Node ID remains E8C3C596-8478-52E4-8577-FF194EC8C0B3. Observe Mac and simulator for that same member's new name with no duplicate, and recovery within 60 seconds. Keep all three apps foregrounded without Refresh/relaunch/background rescue. The documented one/three/five-minute observation and post-rename roundtrip follow; then restore iPhone-Dev-T1 and repeat the recovery/observation checks. User has not yet reported performing the rename. No agent device interaction, source change, build, staging or commit.


### E14 physical-iPhone temporary rename: immediate propagation — November 7, 2026

Following the requested physical-phone Friendly Name change from iPhone-Dev-T1 to iPhone-Dev-E14, user reports “immediate broadcast and display of the name change”. Record immediate user-observed propagation/display; “broadcast” is the user's description, not an independently measured transport mechanism. Exact save time, per-peer timing, duplicate-member absence, unchanged full Node ID and renamed-phone connectivity were not separately reported. No timed stability or post-rename delivery pass yet.

Next bounded step: keep Mac, physical iPhone and original iPhone 17 foregrounded, with no Refresh/relaunch/background rescue; observe at one, three and five minutes after rename. If exact elapsed time is unknown, begin a fresh five-minute observation now and record it as a post-propagation window rather than inventing a save timestamp. Confirm all three remain green, both remote peers retain the new phone name with no duplicate, and the phone retains XYZ node E8C3C596-8478-52E4-8577-FF194EC8C0B3. Report any flicker/orange state/failure at the time it occurs. Post-window bidirectional delivery and restoration to iPhone-Dev-T1 remain pending. E14/full R1 remain open. Documentation only; no agent device action, build, code change, stage or commit.


### E14 temporary-name five-minute observation completed — November 7, 2026

User reports “Completed... no flicker, no name changes” in response to the five-minute observation follow-up. Record completed user-observed five-minute window with no flicker or further name changes after immediate temporary-name propagation. Exact save/window timestamps and individual one/three/five-minute captures were not supplied. Do not infer an independently checked full Node ID or duplicate-member count from this reply. All three apps were instructed to remain foregrounded without Refresh/relaunch/background rescue; no intervention was reported.

Next single step: physical iPhone sends E14-Phone-After-20261107 to original iPhone 17 (iOS 27.0), which replies; verify one receipt each while retaining temporary phone name iPhone-Dev-E14. Post-rename roundtrip is pending. Then restore original name iPhone-Dev-T1 and perform the documented recovery/observation checks. Full E14 and R1 remain open. No agent device interaction, source edits, builds, staging or commits.


### E14 temporary-name post-observation roundtrip — user-confirmed PASS, November 7, 2026

User replied “confirmed” to physical iPhone sending E14-Phone-After-20261107 to original iPhone 17 (iOS 27.0), receiving its reply, and verifying one receipt each while the temporary phone name remains set. Record scoped post-rename bidirectional delivery PASS following the completed five-minute no-flicker/name-stability observation. No independent message IDs or delivery timings captured.

Next single phase: on physical phone only, restore original Friendly Name iPhone-Dev-T1. Note save time; verify Mac and original simulator show the restored name within 60 seconds without a duplicate member, and physical XYZ Node ID remains E8C3C596-8478-52E4-8577-FF194EC8C0B3. Keep all three apps foregrounded without Refresh/relaunch/background rescue, observing at one, three and five minutes for stable green connectivity/name presentation. Restoration has not yet been reported; its observation and final identity/history confirmation remain pending. Full E14 (including other platform/variant results) and R1 remain open. Documentation only; no agent app action, source change, build, staging or commit.


### E14 original Friendly Name restored: immediate propagation — November 7, 2026

User reports “Confirmed... immediate broadcast and display of the new T1 name” after the request to restore physical iPhone Friendly Name to iPhone-Dev-T1. Record restoration and immediate user-observed name propagation/display. “Broadcast” is the user's wording, not a captured protocol trace. This reply does not establish completion of the requested five-minute restoration observation, duplicate-member check or unchanged full Node ID.

Next step remains the restoration stability window: all three apps foregrounded, no Refresh/relaunch/background rescue, checks at one/three/five minutes for green connectivity, retained restored name and no duplicates, plus unchanged XYZ Node ID E8C3C596-8478-52E4-8577-FF194EC8C0B3. Do not repeat the already-passed temporary-name roundtrip. Full E14 and R1 remain open. Documentation only; no agent app interaction, source/build change, stage or commit.


### E14 physical-iPhone foreground rename/restore — scoped PASS, November 7, 2026

User explicitly reports “all aspects are confirmed - pass” against the restored-name five-minute observation: all three apps remain green, no flicker or duplicate member, unchanged physical-phone XYZ Node ID, all foregrounded without Refresh or relaunch. Record original name iPhone-Dev-T1 restored, immediate propagation and completed restoration stability checks. Exact save/recovery timestamps and independently captured per-checkpoint telemetry were not supplied; timing remains user-observed.

Physical-iPhone uninterrupted-foreground variant disposition: scoped PASS. Established sequence: pre-rename physical phone/original iPhone 17 (iOS 27.0) roundtrip with one receipt each; temporary rename iPhone-Dev-T1 → iPhone-Dev-E14 with immediate propagation; completed five-minute observation without flicker/further name changes; post-rename roundtrip with one receipt each; restoration to iPhone-Dev-T1 with immediate propagation; five-minute restoration observation and final unchanged XYZ node E8C3C596-8478-52E4-8577-FF194EC8C0B3/no-duplicate confirmation. Mac was the second foreground observer. No manual recovery reported. Existing E15 identity/history evidence remains valid; this run does not add a full history/storage inventory or an independently measured protocol trace.

E14 overall remains OPEN: Mac and simulator foreground rename/restore executions, inactive-name startup and rename near background/foreground variants remain separately unperformed unless subsequent evidence establishes otherwise. Do not repeat the physical-phone foreground run without a specific reason. Next single phase: Mac foreground Friendly Name variant, starting by recording original Mac name MacMini-Ice-9, Mac XYZ local Node ID, participating build/environment state and a uniquely labelled pre-rename Mac ↔ physical-phone roundtrip. Leave physical-phone name restored and original iPhone 17 as the second observer; do not rename Mac until its baseline is recorded. Last confirmed Network Link Conditioner OFF November 7; reconfirm before the next live network test. E8 authority remains last confirmed Stopped, XYZ authority Running. Full R1 remains open.

Documentation only; no code changes, builds, agent app interactions, profile/membership changes, resets, staging or commits. All existing workspace/index changes preserved.


### E14 Mac foreground variant: environment/name confirmed — November 7, 2026

User replied “confirmed” to Network Link Conditioner remaining OFF and Mac's current Friendly Name being MacMini-Ice-9. Record these prerequisites for the Mac foreground variant. No Mac rename or Mac-variant message test has yet been reported.

Next bounded baseline: record Mac's XYZ local Node ID from This Device, then send E14-Mac-Before-20261107 from Mac to physical iPhone and reply from the phone, verifying one receipt each. Keep Mac, physical phone and original iPhone 17 (iOS 27.0) foregrounded on XYZ; retain current names. Mac's temporary rename and timed observation follow after this baseline. Physical-iPhone foreground variant remains passed; full E14/R1 remain open. Documentation only; no agent app interaction, build, source edit, staging or commit.


### E14 Mac pre-rename baseline — user-confirmed PASS, November 7, 2026

User reports “Success” and “Node ID == ...A98” in response to the requested E14-Mac-Before-20261107 Mac → physical-iPhone message/reply with one receipt each and Mac XYZ local Node ID check. Record pre-rename bidirectional delivery PASS and Mac XYZ node suffix A98; no full UUID or independent message IDs/timing were supplied. Original Mac name remains MacMini-Ice-9; Network Link Conditioner was just reconfirmed OFF. All three apps were instructed to remain foregrounded on XYZ.

Next single step: rename Mac only to MacMini-Ice-9-E14, noting save time; verify both physical iPhone and original iPhone 17 display the new name for the same member without duplicates, Mac recovers/remains green within 60 seconds, and Mac XYZ Node ID remains unchanged from the noted baseline. Keep all three apps foregrounded without Refresh/relaunch/background rescue. Timed one/three/five-minute observation, post-rename roundtrip and restoration to MacMini-Ice-9 remain pending. No rename is yet claimed. Physical-iPhone variant PASS retained; full E14/R1 open. Documentation only; no agent device action, code/build change, staging or commit.


### E14 Mac rename control located in source — November 7, 2026

User could not locate Mac device rename. Read-only inspection confirms BeakrSettingsView has a Device tab containing This Device → Friendly Name and Apply Friendly Name, wired to bootstrap.applyDeviceFriendlyName(). Networks is the default Settings tab. The local member detail page is not the rename route. Direct user to Beakr → Settings (Command-comma) → Device; no new UI implementation is required by this finding. Source availability is not independent verification of the installed Mac UI. Mac rename remains pending. No code/device/build/staging changes.


### E14 Mac rename blocked: Device tab reported nonfunctional — November 7, 2026

User reports “The Device Tab does not work.” Mac foreground rename acceptance is paused before the temporary rename. Source inspection confirms Device/Networks String tags match their AppStorage-backed selection, and the only other located assignment selects Networks when opening network settings. This does not establish the runtime failure cause. Distinguish tab failing to select, selecting with blank/wrong contents, and an inoperative name/apply control before changing code. Request screenshot after clicking Device and a brief description of which behavior occurs. Do not claim that source presence proves the installed UI works, or work around it with defaults/profile edits.

Existing Mac pre-rename delivery PASS and physical-iPhone E14 PASS stand. No Mac rename, source change, build, automated Mac interaction, staging or commit occurred in this investigation. Existing memberships/history and hosting remain untouched by agent.


### Mac Settings Device tab nonresponsive: candidate correction — November 7, 2026, 18:49

User explicitly confirms clicking Device leaves the Networks UI unchanged. This blocks E14 Mac rename before any temporary name change. Source has matching legacy String tags and no established selection-reset loop; exact framework/runtime cause is not proven. Applied a focused candidate correction in Apps/Beakr/ContentView.swift: BeakrSettingsView now uses TabContentBuilder with explicit Tab("Device", ..., value:) and Tab("Networks", ..., value:) declarations instead of legacy .tabItem/.tag view modifiers. Preserved existing selection storage, settings contents, model ownership and rename action. No service/identity/history changes.

Consulted swiftui-specialist guidance and local Apple DocumentationSearch for TabView selection and Settings. Current documentation uses explicit Tab declarations; migration alone is not proof of runtime repair. Xcode BuildProject passed Beakr/My Mac, BuildProject-Log-20261107-184905.txt, no errors. No agent launch/install or Mac UI interaction; user must Run over the existing installation and verify Settings → Device, then Networks → Device again, before resuming rename acceptance. Existing Mac pre-rename roundtrip predates this build/relaunch; retain it as prior evidence and assess a fresh baseline after deployment. Physical-iPhone E14 and E15 passes remain intact.

Xcode left on My Mac. No stage/commit/reset or live profile changes. Workspace/index preserved. git diff --check passed after documentation update. Runtime Device-tab fix acceptance remains PENDING.


### Mac Settings tab migration retest FAIL; explicit pane selection built — November 7, 2026, 18:51

User confirms Device still does not change the UI after the 18:49 candidate. Retain that failed runtime retest; modern Tab declarations alone did not solve it. Read-only console verified current Mac session 7c6c575500/PID 82224 by macOS sender image path; startup reached ready and two connected peers. No diagnosis of tab failure follows from connectivity. Shell defaults reads could not access the app domain; no preference values were changed.

Replaced only BeakrSettingsView's TabView selector with a Picker and explicit conditional Device/Networks content. Uses documented .pickerStyle(.tabs), which is intended for pane navigation and announces tabs to VoiceOver. Existing persisted selection, both pane contents and Friendly Name action remain. The picker sits above the selected pane rather than relying on Settings' native toolbar tab hosting. Framework failure cause remains unproven; this directly controls content selection instead of repeating the unsuccessful tab migration. NetworkManagerWindow's transient view state is recreated when returning to it; existing persisted network selection and column visibility remain. Service/model ownership stays outside the pane switch.

Final Xcode BuildProject Beakr/My Mac PASS: BuildProject-Log-20261107-185113.txt (earlier segmented-style intermediate build 185100 also passed). Runtime acceptance pending user Run and Settings Device → Networks → Device inspection; no agent launch or Mac app interaction. No test suite rerun for this narrow presentation change. git diff --check passed. E14 Mac rename remains paused, name unchanged; retain other accepted evidence. No reset/stage/commit; existing workspace/index preserved. Xcode remains My Mac.


### Mac Device pane visible; blank Friendly Name editor corrected — November 7, 2026, 18:53

User screenshot at 18:52 shows the new selector displaying Device contents, establishing scoped Device-pane visibility after the selector fix (full back-and-forth navigation not independently established). Friendly Name row is blank and Apply disabled, while simulator still shows MacMini-Ice-9. Source explains this discrepancy: deviceFriendlyName defaults to an empty custom override, whereas deviceDisplayName falls back to the system Mac computer name. Previous editor bound directly to the empty override. Screenshot also records full Mac XYZ Node ID 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98.

Focused correction: DeviceDetailsSection receives deviceDisplayName, initializes a private nameDraft on appearance, uses a rounded-border text field, and passes the draft to its apply callback. Only Apply/Return sets deviceFriendlyName and invokes the existing runtime-restart path; opening/editing the draft does not persist a name or restart messaging. No transport/hosting/identity changes. Navigation away discards an unapplied draft; re-entry initializes from current displayed name.

Xcode BuildProject Beakr/My Mac PASS: BuildProject-Log-20261107-185312.txt. git diff --check passed. User Run and verification of populated/editable MacMini-Ice-9 field remain pending; agent did not launch/interact with Mac. E14 Mac temporary rename remains not performed. Keep all previous failed retests and scoped passes. No resets, profile changes, staging or commits; Xcode remains My Mac.


### Mac Friendly Name editor accessible — user-confirmed, November 7, 2026

User reports “Yes it provides the UI from which a name could be changed” after the 18:53 build and requested Device-pane inspection. Record scoped confirmation that the Mac name-editing UI is accessible. No actual rename/application, propagation or persistence is established by this reply; do not mark E14 Mac complete. Earlier native-tab failures and blank-override defect remain recorded with their corrections.

Mac foreground E14 resumes with a fresh pre-rename message baseline because the Mac was rebuilt/relaunched during the UI correction. This is a specific reason to repeat baseline delivery, not a repeat of passed E15 or physical-iPhone E14. Next user step: with all three apps foregrounded on XYZ and Network Link Conditioner still OFF, send E14-Mac-Before-2-20261107 from Mac to physical iPhone and reply, verifying one receipt each. Retain original name MacMini-Ice-9 until that result. Full Mac XYZ Node ID recorded from screenshot: 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98. Mac rename/observation/restore remain pending. Documentation only; no agent app interaction, build, source edit, staging or commit.


### E14 Mac refreshed pre-rename baseline — November 7, 2026

User confirms all three apps foregrounded and message sent/replied successfully following the requested E14-Mac-Before-2-20261107 Mac/physical-phone exchange. Record successful user-observed bidirectional delivery on the rebuilt Mac. Duplicate counts and current Conditioner state were not separately restated in this reply; Conditioner remains last explicitly confirmed OFF earlier in the session. No Mac rename yet reported.

Next user step: confirm Conditioner remains OFF, then change only Mac Friendly Name from MacMini-Ice-9 to MacMini-Ice-9-E14 using Apply Friendly Name. Record save time and initial propagation to physical iPhone/original iPhone 17, unchanged Mac XYZ Node ID 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98, no duplicate member and green recovery within 60 seconds. Keep apps foregrounded with no manual recovery; one/three/five-minute stability checks follow. Full E14/R1 remain open; accepted physical-phone E14 and E15 evidence retained. Documentation only; no agent app action, build, source change, stage or commit.


### E14 Mac temporary rename: immediate propagation and identity continuity — November 7, 2026

After the requested MacMini-Ice-9 → MacMini-Ice-9-E14 change, user reports “All green”, immediate name propagation/display, and unchanged Node ID. Record user-observed initial propagation, green connectivity and Mac XYZ identity continuity against baseline 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98. Exact save/recovery timestamps and duplicate-member absence were not separately supplied. “Broadcast” is user wording, not an independently captured protocol mechanism.

Next single step: keep Mac, physical phone and original iPhone 17 foregrounded for five minutes, observing at one/three/five minutes for stable green connectivity, retained temporary Mac name and no duplicate member. No Refresh/relaunch/background rescue. Report any flicker or failure immediately. Post-observation Mac/phone roundtrip and original-name restoration remain pending. Full E14/R1 remain open. Documentation only; no source/build/device automation, staging or commit.


### E14 Mac temporary-name observation update — November 7, 2026

User reports “No flicker, no name change” and “Node ID == ... A98” following the requested timed observation. Record stable user-observed presence/name and identity suffix consistent with Mac XYZ baseline 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98. Reply does not explicitly state elapsed five minutes or duplicate-member absence; do not invent timestamps/checkpoint captures.

Next bounded step after the full five-minute window: send E14-Mac-After-20261107 from Mac to physical iPhone and reply, confirm one receipt each and no duplicate Mac member on either iPhone. Retain temporary Mac name until this roundtrip completes. If five minutes have not elapsed, finish that observation first. Original-name restoration remains pending. No new full E14/R1 pass. Documentation only; no agent app action, code/build change, staging or commit.


### E14 Mac temporary-name post-observation roundtrip — user-confirmed PASS, November 7, 2026

User replied “Success” to the requested post-five-minute E14-Mac-After-20261107 Mac → physical-iPhone exchange/reply, one receipt each and no duplicate Mac member on either iPhone. Record scoped user-confirmed post-rename bidirectional delivery and duplicate-member check PASS. The requested ordering placed this after the five-minute window; no independent timestamps or message IDs were captured. Prior no-flicker/stable-name and unchanged A98 suffix observations stand.

Next single phase: restore only Mac Friendly Name from MacMini-Ice-9-E14 to MacMini-Ice-9 using Apply Friendly Name. Verify restored name on both iPhones, green connectivity, unchanged Mac XYZ Node ID 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98, and no duplicate member; keep all three apps foregrounded without Refresh/relaunch/background rescue for five minutes with one/three/five-minute observations. Restoration not yet reported. Full E14/R1 remain open. Documentation only; no agent app action, code/build change, staging or commit.


### E14 Mac foreground rename/restore — scoped PASS, November 7, 2026

User reports original-name restoration happened/displayed immediately, Node ID remains ...A98, and “Success - no flicker, no names changes” in response to the requested five-minute restoration procedure. Record user-reported restoration success/stability within that requested scope; exact elapsed times and individual checkpoint captures were not supplied. Original Mac name MacMini-Ice-9 is restored. No Refresh/relaunch/background rescue was reported during the rename observations.

Mac uninterrupted-foreground variant disposition: scoped PASS. Evidence comprises the rebuilt-Mac pre-rename roundtrip, immediate temporary-name propagation to peers with all green and unchanged identity, stable temporary-name observation, post-observation bidirectional delivery/one-copy/no-duplicate confirmation, and immediate original-name restoration with stable display and unchanged A98 identity suffix. Full Mac XYZ node previously screenshot-recorded as 1FF7E8E1-E855-5A3C-AE55-25179B1E9A98. No independent transport timing, full storage comparison or newly measured history inventory is inferred.

Settings blockers retain their history: native Device tab remained nonresponsive after modern Tab migration; explicit pane selector made Device visible; editor then corrected to initialize a local draft from the effective name rather than an empty override. User subsequently accessed and exercised the editor through the complete Mac rename/restore run. Final source was built via Xcode BuildProject at 18:53; no further source changes were needed during acceptance.

E14 overall remains OPEN for original-simulator foreground rename/restore and separate inactive-name/startup and near-background/foreground variants. Physical-phone and Mac foreground passes stand; no repeat required without a specific reason. Next single phase: original iPhone 17 / iOS 27.0 (DE26C44E-C798-4645-B26C-FF891A09F71F) foreground rename baseline. Record current simulator Friendly Name (last displayed iPhone-17), XYZ Node ID and pre-rename simulator/Mac roundtrip before changing its name. Physical iPhone remains the second observer, original name iPhone-Dev-T1. Do not use the distinct iOS 27.2 iPhone 17 or archived iPhone 18 Pro. Reconfirm current Network Link Conditioner OFF before further live testing.

Full R1 remains open. E8 authority last confirmed Stopped; XYZ authority last confirmed Running. No agent device interaction, builds, code changes, resets, staging or commits in this recording phase. Existing workspace and index preserved.


### E14 original simulator foreground baseline identity/environment — November 7, 2026

User explicitly identifies iPhone-17 (27.0), confirms Network Link Conditioner OFF, Friendly Name iPhone-17, and Node ID suffix 629. This matches the original simulator's historically established XYZ identity F12D8774-7350-5FBA-9125-690477546629, but is not a fresh full-UUID capture. Use only this user-operated simulator, DE26C44E-C798-4645-B26C-FF891A09F71F; the separate iOS 27.2 instance is outside this run.

Next bounded step: keep Mac, physical iPhone and original simulator foregrounded on XYZ; send E14-Sim-Before-20261107 from original simulator to Mac and reply, verifying one receipt each. Leave Friendly Name iPhone-17 unchanged until baseline delivery passes. Temporary rename, timed observation, post-rename delivery and restoration remain pending. Physical-phone/Mac foreground passes stand; full E14/R1 remain open. Documentation only; no agent app interaction, source/build change, staging or commit.


### E14 original simulator pre-rename roundtrip — user-confirmed PASS, November 7, 2026

User reports “Message exchange == success” following the requested E14-Sim-Before-20261107 original iPhone 17 (iOS 27.0) → Mac message and reply, with one receipt each requested. Record scoped user-confirmed baseline exchange success; no independent message IDs, timing or copy counts captured. Simulator original Friendly Name remains iPhone-17, XYZ node suffix 629, Conditioner last explicitly OFF for this phase.

Next single step: on original iPhone 17 (27.0) only, change Friendly Name to iPhone-17-E14 and save. Note save time; verify Mac and physical phone display it without duplicates, all remain/recover green within 60 seconds, and simulator Node ID remains unchanged from the baseline ending 629. Keep all three apps foregrounded, without Refresh/relaunch/background rescue. Timed observation, post-rename roundtrip and restoration to iPhone-17 remain pending. No rename yet claimed. Full E14/R1 remain open. Documentation only; no agent device action, source/build change, staging or commit.


### E14 original simulator temporary rename: initial checks confirmed — November 7, 2026

User replied “confirmed” to the requested iPhone-17 (iOS 27.0) → iPhone-17-E14 rename, display on Mac and physical phone within 60 seconds without duplicates, all green, and unchanged simulator Node ID suffix 629. Record scoped user-confirmed initial propagation/connectivity/identity checks. Exact save/recovery times were not supplied; no timed stability or post-rename delivery pass yet.

Next single step: keep all three apps foregrounded for five minutes and check at one/three/five minutes for green connectivity without flicker, retained iPhone-17-E14 name, no duplicate simulator member and unchanged identity. No Refresh/relaunch/background rescue. Post-window simulator/Mac roundtrip and original-name restoration remain pending. Full E14/R1 remain open. Documentation only; no agent device interaction, source/build changes, staging or commit.


### E14 original simulator temporary-name observation — user-confirmed PASS, November 7, 2026

User reports “Pass”, no flicker, no name change, and Node ID ...629 after the requested five-minute foreground observation with one/three/five-minute checks. Record scoped user-observed stability and identity continuity. Exact observation timestamps and independent checkpoint captures were not supplied. Initial no-duplicate/all-green confirmation remains prior evidence; no manual recovery was reported.

Next single step: send E14-Sim-After-20261107 from original iPhone 17 (iOS 27.0), still named iPhone-17-E14, to Mac and reply. Verify one receipt each with all three apps foregrounded. Post-rename delivery and subsequent restoration to iPhone-17 remain pending. Full E14/R1 remain open. Documentation only; no agent device interaction, code/build changes, staging or commit.


### E14 original simulator post-rename exchange — user-confirmed PASS, November 7, 2026

User reports “Message exchange == success” after the requested E14-Sim-After-20261107 original iPhone 17 (iOS 27.0) → Mac message and reply under temporary name iPhone-17-E14. Record scoped bidirectional delivery success; one receipt each was requested, with no independent message IDs/copy-count trace captured. Temporary-name five-minute stability and unchanged node suffix 629 remain passing prior observations.

Next single phase: restore original simulator Friendly Name to iPhone-17. Verify propagation to Mac/physical iPhone, all green, no duplicate member and unchanged XYZ Node ID suffix 629. Keep all three apps foregrounded without Refresh/relaunch/background rescue for five minutes, checking at one/three/five minutes for stable restored name and connectivity. Restoration remains pending; simulator foreground variant/full E14/R1 not yet complete. Documentation only; no agent device interaction, code/build change, staging or commit.


### E14 original simulator restored-name observation — November 7, 2026

Following the requested restoration to iPhone-17, user reports immediate name propagation/display, no flicker, no subsequent name changes and XYZ remaining green. Record these restored-name/connectivity observations. Exact elapsed duration, final unchanged node suffix 629 and duplicate-member absence were not explicitly restated in this reply. Do not convert the report into independently measured timing or full identity verification.

Next bounded confirmation: establish that the full five-minute restoration window is complete, simulator XYZ Node ID still ends 629, and neither peer shows a duplicate simulator member. No further rename or message exchange requested. Simulator foreground variant awaits that final confirmation; physical-phone/Mac foreground passes stand. Full E14/R1 remain open. Documentation only; no agent device action, source/build changes, staging or commit.


### E14 original simulator restored identity confirmed — November 7, 2026

User replies “still... 629”, explicitly confirming the restored simulator's XYZ Node ID suffix remains unchanged. This closes the final identity check. Restored-name propagation, no flicker/name changes and green XYZ were previously reported. Final confirmation of the full five-minute restoration interval and no duplicate member remains pending; no further identity recheck is needed. Documentation only; no device/source/build/staging changes.


### E14 original simulator foreground rename/restore — scoped PASS, November 7, 2026

User replied “yes” to confirmation that five minutes elapsed after original-name restoration and neither Mac nor physical iPhone showed a duplicate simulator member. Combined with explicit restored-name propagation, no flicker/further name changes, green XYZ and unchanged node suffix 629, this closes the original iPhone 17 (iOS 27.0) uninterrupted-foreground variant as scoped PASS.

Completed sequence: original name iPhone-17; pre-rename simulator/Mac exchange; temporary name iPhone-17-E14 with prompt peer propagation/all-green/no-duplicate/identity confirmation; five-minute stable observation; post-rename simulator/Mac exchange; original-name restoration; five-minute stable restoration observation with final identity/no-duplicate confirmation. Simulator UUID DE26C44E-C798-4645-B26C-FF891A09F71F; historical full XYZ node F12D8774-7350-5FBA-9125-690477546629. Timing and delivery are user-observed, not independent protocol/message-ID traces. The distinct iOS 27.2 simulator was not used.

E14 foreground variants now PASS separately on physical iPhone, Mac and original simulator. Restored names: iPhone-Dev-T1, MacMini-Ice-9, iPhone-17. No repeats warranted without new changes/failures. E14 overall remains OPEN for the documented inactive-name/next-startup and near-background/foreground variants; full R1 remains open with other previously recorded evidence/disposition boundaries.

Next single phase is preparation for the inactive-name/startup variant. Use an existing participant's supported messaging-off control if available; do not confuse selecting an inactive network's details with stopping messaging, and do not switch profiles solely to simulate no active runtime. Inspect source/control semantics before directing user actions. Reconfirm current Conditioner/hosting state only when starting that live phase. No new live action requested by this entry. All three foreground results and E15 remain accepted within their recorded scopes. Documentation only; no agent device interaction, source/build changes, reset, staging or commit.


### E14 inactive-startup feasibility and next lifecycle phase — November 7, 2026

Read-only source review finds no supported Stop Messaging/deactivate control while keeping the name editor available. Use for Messaging changes the single selected network; Stop Authority Hosting controls a separate service and does not stop messaging. NodeBootstrapModel.applicationDidEnterBackground stops the LAN runtime; applicationBecameActive automatically restarts it, so returning to the name editor does not leave messaging inactive. applyDeviceFriendlyName has a state != ready save-for-next-startup branch, but the existing friendlyNameRestartPreservesConnectivity test exercises the ready-state restart/failure/retry path, not that branch. Do not claim inactive-save coverage from those tests or from inspecting inactive-network details.

Inactive-save/next-startup variant: NOT RUN through live UI; pending isolated fixture coverage or explicit acceptance disposition. This is not silently waived/passed. Do not add a Stop Messaging feature, manipulate live preferences/profile state, induce a failed network or re-enroll solely to manufacture this condition. No new code/test executed in this review.

Next single executable phase: physical-iPhone rename immediately before a normal background/foreground transition. Prepare with Conditioner OFF, Mac XYZ hosting/messaging Running, E8 hosting Stopped, all three participants foregrounded/green on XYZ, original phone name iPhone-Dev-T1. Then record baseline phone XYZ ID/history and a uniquely labelled phone/Mac exchange before temporary rename to iPhone-Dev-E14-BG. Save then promptly go Home, stay backgrounded about 10 seconds, return once; record action times and automatic recovery within 60 seconds. The background/return is the planned stimulus, not a rescue; any additional Refresh/relaunch/repeated lifecycle rescue is a failure to diagnose. Timed observation, delivery and original-name restoration follow in separate user steps. Do not perform any transition until prerequisites are confirmed. Original simulator iOS 27.0 is second observer; iOS 27.2 duplicate and iPhone 18 Pro remain outside the run.

All three foreground E14 variants and E15 remain passed within recorded scopes. Full E14/R1 remain open. Documentation only; no builds, device actions, profile changes, staging or commits.


### E14 physical-iPhone lifecycle variant prerequisites confirmed — November 7, 2026

User replied “true” to Conditioner OFF, Mac XYZ authority Running, E8 authority Stopped, and all three participating apps foregrounded/green on XYZ. Record those current prerequisites for the planned rename-near-background/foreground variant. No lifecycle transition or temporary rename has yet been performed in this variant.

Next bounded baseline: with phone name still iPhone-Dev-T1, send E14-Phone-BG-Before-20261107 from physical iPhone to Mac and reply, confirming one receipt each. Check phone XYZ Node ID still ends C0B3 and existing XYZ history remains visible. Original iPhone 17 (iOS 27.0) remains the second observer. This baseline is for a distinct lifecycle variant, not a repeat of accepted uninterrupted-foreground acceptance. Full E14/R1 remain open. Documentation only; no agent app interaction, source/build change, staging or commit.


### E14 physical-iPhone lifecycle baseline — user-confirmed PASS, November 7, 2026

User replied “confirmed” to E14-Phone-BG-Before-20261107 physical-phone/Mac message and reply, one receipt each, phone XYZ Node ID suffix C0B3 and existing history visibility. Original name iPhone-Dev-T1 and all-three-foreground instructions remain in place. Record scoped user-confirmed baseline; no independent message/timing trace.

Next single stimulus: on physical iPhone only, save Friendly Name iPhone-Dev-E14-BG, promptly go to Home without waiting for propagation, remain backgrounded about 10 seconds, then reopen Beakr once. Note save/background/return times or approximate intervals. Keep Mac and original iPhone 17 (iOS 27.0) foregrounded throughout. Observe automatic recovery for up to 60 seconds after return: phone green, new name on both peers, no duplicate member, unchanged phone XYZ node suffix C0B3. Planned background/return is test stimulus; no additional Refresh/relaunch/background rescue. If recovery fails, report that state before further action. No rename/transition yet claimed; stability/delivery/restoration follow separately. Full E14/R1 open. Documentation only; no agent device interaction, source/build changes, staging or commit.


### E14 physical-iPhone rename/background/return: initial recovery PASS — November 7, 2026

User reports “pass” against the requested sequence: save iPhone-Dev-E14-BG, promptly go Home for about 10 seconds, reopen Beakr once, then within 60 seconds verify phone green, temporary name displayed on Mac/original simulator, no duplicates and unchanged XYZ Node ID suffix C0B3. Record scoped user-confirmed initial lifecycle recovery. Approximate/exact action timestamps were requested but not supplied; do not claim measured timing or a precisely captured rename/restart race. No additional Refresh/relaunch/repeated lifecycle rescue was reported. The single background/return is the intended stimulus.

Next single phase: keep all three apps foregrounded for five minutes after return, check at one/three/five minutes for stable green connectivity, retained iPhone-Dev-E14-BG name and no duplicate phone member. Report instability immediately; otherwise confirm completion. Post-window phone/Mac exchange, original-name restoration and final identity/history checks remain pending. Full lifecycle-variant acceptance/E14/R1 remain open. Documentation only; no agent device action, source/build changes, staging or commit.


### E14 physical-iPhone lifecycle recovery timing and stability — scoped PASS, November 7, 2026

User clarified the preceding recovery as “immediate”, then reported “pass”, no name change, no flicker and ID ...0B3 after the requested five-minute foreground observation at one/three/five minutes. Record user-observed immediate recovery and completed stable post-transition window, with identity suffix consistent with XYZ node E8C3C596-8478-52E4-8577-FF194EC8C0B3. “Immediate” is qualitative; no exact timestamps, independent latency or checkpoint captures supplied. Initial no-duplicate confirmation remains recorded; no manual rescue reported.

Next single step: send E14-Phone-BG-After-20261107 from physical phone, still named iPhone-Dev-E14-BG, to Mac and reply; verify one receipt each with all three apps foregrounded. Post-transition delivery and restoration to original iPhone-Dev-T1 remain pending. Lifecycle variant/full E14/R1 not yet complete. Documentation only; no agent device interaction, source/build changes, staging or commit.


### E14 physical-iPhone lifecycle post-transition roundtrip — user-confirmed PASS, November 7, 2026

User reports “pass” to E14-Phone-BG-After-20261107 physical iPhone → Mac and reply, with one receipt each, while retaining iPhone-Dev-E14-BG and all apps foregrounded. Record scoped user-confirmed post-transition bidirectional delivery PASS. No independent message IDs or timings captured.

Next single cleanup/verification phase: restore physical phone name to iPhone-Dev-T1; keep all three apps foregrounded, confirm restored name on peers, green connectivity, no duplicates/flicker and unchanged XYZ identity/history, and observe for five minutes at one/three/five minutes. No additional background transition, Refresh or relaunch requested. Restoration remains pending; lifecycle variant/full E14/R1 remain open. Documentation only; no agent device action, code/build changes, staging or commit.


### E14 physical-iPhone rename near background/foreground — scoped PASS, November 7, 2026

User replied “confirmed” to original-name restoration (iPhone-Dev-T1), five-minute foreground observation, restored name on peers, all green/no flicker/no duplicates, unchanged XYZ Node ID suffix C0B3 and existing XYZ history visibility. Record restoration and final preservation/stability checks as user-confirmed PASS.

Lifecycle variant outcome: scoped PASS on physical iPhone. Pre-transition phone/Mac exchange passed; phone renamed to iPhone-Dev-E14-BG and promptly backgrounded for the requested approximately 10 seconds, then reopened once; user reported immediate recovery, green connectivity, peer name propagation/no duplicates and unchanged identity; five-minute observation passed; post-transition one-copy roundtrip passed; original-name restoration/final five-minute identity/history checks passed. Planned background/return was the stimulus, with no additional recovery intervention reported. Exact action times, rename/restart race interleaving and independent message/transport traces were not captured. This result does not certify every lifecycle timing or other platforms' background variants.

E14 status: foreground rename/restore PASS separately on physical iPhone, Mac and original iPhone 17 (iOS 27.0); physical-iPhone near-background/foreground variant PASS. Inactive-save/next-startup remains NOT RUN through live UI because no supported messaging-off/editor path exists. Existing ready-state rename fixture does not cover that branch; isolated coverage or explicit disposition remains needed. No automatic expansion to exhaustive per-platform lifecycle permutations. Full E14 and R1 remain open pending the recorded evidence/dispositions.

All three original names restored: iPhone-Dev-T1, MacMini-Ice-9, iPhone-17. XYZ last confirmed green with history intact; Mac XYZ hosting last confirmed Running, E8 hosting Stopped; Conditioner last confirmed OFF November 7. Next single phase: isolated regression coverage for saving a name before runtime startup and advertising it on normal startup, using disposable fixture state and the authorized baseline simulator only. Do not alter live profiles, names or defaults to manufacture an inactive state. No live-device action needed for that preparation.

Documentation only in this recording phase; no agent app action, build, source edits, resets, staging or commits. Existing workspace/index preserved.


### E14 inactive-save/normal-startup fixture — PASS, November 7, 2026, 19:58

Added BeakrTests.friendlyNameSavedBeforeStartup using a UUID-named disposable UserDefaults suite, signed disposable credential/profile fixtures, MemoryProfileRuntimeManager and TestLANRuntimeManager. A small dependency-injection seam in NodeBootstrapModel routes Friendly Name persistence through friendlyNameDefaults; production constructors retain UserDefaults.standard and the same key/behavior. The injected constructor loads from the supplied suite. No live preferences were edited to manufacture an inactive state.

The regression saves/normalizes a name before model startup, verifies persisted suite value and zero runtime starts/stops, unchanged fixture profile inventory, then creates a new model with the same suite. Normal startup advertises the persisted name via the injected runtime's displayName argument, starts once, retains node/profile IDs and reaches connected fixture state. Test finishes by backgrounding its fixture runtime and removing its suite. It uses no real peer transport or live profile credentials. It is application-model/startup wiring evidence, not live Bonjour reception or rendered-app inactive-state acceptance.

Validation: Xcode BuildProject(buildForTesting: true) passed Beakr / Beakr-R1-Contract-Baseline-20261026, log BuildProject-Log-20261107-195835.txt. GetTestList discovered the new test. Xcode RunSomeTests on that authorized baseline passed 1/1, summary C8A11E6C-AB99-46E2-A217-E7608CF67E13.txt; xcresult Test-Beakr-2026.11.07_19-58-44--0500.xcresult; artifact root /var/folders/43/dksvm3zs65111c772c5fp3tw0000gn/T/ActionArtifacts/FDF24040-C162-41A6-998B-799DE54A413E/. Existing passed live rename runs were not repeated. git diff --check passed. Xcode returned to My Mac after testing.

E14 evidence now includes three platform-specific foreground live passes, physical-iPhone near-background/foreground live pass, and inactive-save/startup fixture PASS. The inactive-save LIVE UI variant remains NOT RUN because no supported messaging-off/editor route exists. Recommended disposition: accept the fixture for that branch together with the live rename/startup evidence, retaining the explicit live-UI limitation; this recommendation is not user acceptance or an automatic full E14/R1 signoff. Do not invent an editor-off feature or force live failure just to satisfy that variant.

Source changes limited to the Friendly Name preference injection and new regression. Baseline-only automated test execution; no physical/Mac/other-simulator app actions. All live identities, memberships, histories and existing workspace/index changes preserved; no reset, stage or commit. Full R1 still requires remaining documented evidence dispositions and final build/install inventory.


### E14 acceptance disposition approved — November 7, 2026

User explicitly answered “yes” to accepting the inactive-save/normal-startup isolated regression as coverage for the unavailable live-UI variant, retaining that limitation. This is the requested acceptance disposition, not a new live test pass.

E14 disposition: COMPLETE within the agreed scope. Evidence: physical-iPhone, Mac and original iPhone 17 (iOS 27.0) uninterrupted-foreground rename/restore passes; physical-iPhone rename near normal background/foreground pass; inactive-save/startup fixture PASS (1/1 on authorized baseline), accepted by user in place of the unavailable live-UI variant. Preserve exact scopes, qualitative timing, fixture transport limits, historical failures and fixes. No claim of exhaustive lifecycle interleavings or all-platform background coverage. Original friendly names restored; no further E14 rerun required without a specific regression reason.

E15 remains accepted within its documented scope. Full R1 remains OPEN. Next single phase: read-only final evidence/disposition reconciliation for E1/E3 freshness-boundary traces, E2 verified generation/admission evidence, E6/E11 resource/timing limitations, E9 live old-credential authorization limits, E13 unavailable clean-Mac/failure UI variants, and final build/source/install inventory. Do not treat this E14 approval as a blanket waiver of those items. Do not repeat passed live checks, change memberships or touch archived iPhone 18 Pro. No further device action requested in this recording phase.

Documentation only; no build, source/device changes, resets, staging or commits. Existing workspace/index preserved; Xcode remains last selected My Mac.


### Final R1 evidence reconciliation — November 7, 2026

Updated the top of R1-Signoff-Audit-2026-11-01.md with current November 7 evidence, superseding stale implementation/UI/E14/E15 pending claims while preserving historical audits. E14 user-approved scope and E15 remain complete. E1/E3 boundary traces, E2 live generation, E6/E11 resource/timing, E9 live old-credential limits, E13 unavailable clean-Mac variants and final build/install inventory remain explicit dispositions/work, not silently waived.

Identified the next distinct functional assertion from the existing independent-hosting specification: Mac itself switches messaging while the existing XYZ authority remains the same/reachable. No direct post-implementation live record found; phone E15 and port-change passes do not establish it. Prepare this single bounded continuity phase next, preserving existing networks/history and user-operated Mac. Do not repeat passed tests or expand into concurrent messaging/Host-Co-Host roles.

Read-only source/config manifest /tmp/Beakr-R1-source-inventory-20261107.json: 269 entries, SHA-256 d81649d55370f6b7e5b0ed5e45ea8819a40e1dab7ea09f0fe1d58c98c9c53d61; HEAD 9830e3d02724515ed058a55c6146e1c5316b3409; index diff SHA-256 406962e8224cf70c6bde422210af137653397a5153f64df5cca82b62885e9584. Manifest scope/limits and per-participant incremental build inventory are in the audit; no final binary certification. Host macOS 27.0/26A428. No builds/tests, app/device actions, source edits, staging or commits. Full R1 open.


### Mac messaging-switch / authority continuity — preconditions, November 7, 2026

User reconfirmed Network Link Conditioner OFF, Mac and physical iPhone messaging on XYZ, Mac XYZ authority Running and R1-E8-Test authority Stopped. Read-only console verification identifies running macOS Beakr session 7c6c5e5800 / PID 82741; executable metadata is the macOS Debug Beakr.app/Contents/MacOS/Beakr.debug.dylib. XYZ profile-membership handling appears at 20:26:15.908, adjacent to TLS server activity on local port 49986. This establishes baseline handling, not independently verified client response acceptance.

Read-only lsof baseline: PID 82741 listener port 49986, FD 4u, socket identifier 0x72d54417cbe25a17; second listener port 49989, FD 14u, socket identifier 0x78c3a205b3a4dd0c. Retain these for before/after comparison; no messaging switch performed yet and no continuity PASS claimed. Next user-operated step: enable existing R1-E8-Test authority hosting while keeping Mac/phone messaging on XYZ, then confirm both authorities Running. No profile creation, membership changes, build, agent app interactions, stage or commit. Index diff hash remains 406962e8224cf70c6bde422210af137653397a5153f64df5cca82b62885e9584. Full R1 remains open.


### Mac authority continuity — both hosts enabled, November 7, 2026

User confirmed XYZ and R1-E8-Test Authority Hosting both Running after starting only existing E8 hosting, with messaging kept on XYZ as instructed. Read-only verification: macOS session 7c6c5e5800 / PID 82741 remains running. XYZ listener remains port 49986, FD 4u, socket identifier 0x72d54417cbe25a17; port 49989 listener also unchanged. New listener port 49990, FD 16u, socket identifier 0x2b9df8849100957a appears after E8 hosting start (temporal association, not independent network-to-port attribution). No Mac messaging switch yet; no full continuity PASS. Next single user step: select Use Messaging for R1-E8-Test on Mac only, leave physical phone on XYZ and both hosting services enabled, then report E8 selection/status and both hosting states. No agent app action, build, profile/membership change, staging or commit.


### Mac messaging switched to E8 — listener continuity observed, November 7, 2026

User initially reported both authorities Running but E8 messaging Inactive; that was not treated as a completed messaging switch. After selecting Use Messaging for E8, user confirmed the messaging icon on E8, blue network row and one active device. Verified macOS console session 7c6c5e5800 / PID 82741 logs the profile switch at 20:32:37.368 from XYZ profile 9EBC75CA-932A-413D-B0C3-1511180ACBE8 to E8 profile 3C7F3831-8964-4383-8B11-185B472377FF, followed by E8 revocation/membership handling at 20:32:38.

Read-only listener comparison after switch: XYZ port 49986 remains FD 4u with identical socket identifier 0x72d54417cbe25a17 in the same process; port 49990 remains FD 16u / 0x2b9df8849100957a. The other listener changes from port 49989 to 49991 (FD 14u / 0xb25c2fc35ae5a42d), consistent with messaging runtime replacement. This supports preservation of the existing XYZ listening socket across messaging selection; successful remote XYZ refresh after switch remains pending. Next single step: physical phone, still on XYZ, uses its existing network Refresh once to exercise authority reachability while Mac messaging stays E8. This is a deliberate request stimulus, not an automatic recovery claim. No agent app action, build, source changes, staging or commit. Return/cleanup and full R1 remain pending.


### Mac messaging switch preserves XYZ authority service — scoped PASS, November 7, 2026

After Mac messaging switched XYZ → R1-E8-Test, user reports the requested physical-iPhone XYZ Refresh completed with no errors and XYZ members remained visible. Desktop screenshot at 20:37 shows Mac E8 selected for messaging, blue with one device online; XYZ inactive for Mac messaging with five saved members UnObserved, and both XYZ/E8 green authority icons. Screenshot alone does not show the physical phone; its refresh result is user-reported. Historical saved names in inactive XYZ are not evidence of current presence.

Verified macOS console session 7c6c5e5800 / PID 82741 records XYZ credential-revocations at 20:34:43.581 and profile-membership at 20:34:43.612, after the Mac profile switch at 20:32:37. TLS server activity on local port 49986 with a remote en0 link-local address accompanies these operations. Read-only lsof still shows XYZ's original listener port 49986 / FD 4u / socket identifier 0x72d54417cbe25a17 in the same process. E8-associated port 49990 also remains unchanged. Together with the user-reported successful client refresh, this supports scoped PASS for XYZ authority listener/service continuity while the hosting Mac uses E8 messaging. No client-side signed generation or response payload was independently captured; no claim of every request succeeding or exhaustive zero-duration interruption detection. The deliberate Refresh is a service probe, not automatic recovery evidence.

Return/cleanup remains pending: user to restore Mac Use Messaging to XYZ, confirm green and existing XYZ identity/history, then stop temporary E8 hosting while retaining XYZ hosting. Full R1 remains open. No agent app interaction, source change, build, staging or commit.


### Mac authority-continuity phase — return to XYZ confirmed, November 7, 2026

User confirmed Mac messaging restored to XYZ, green status, unchanged Mac XYZ Node ID suffix A98 and existing XYZ messages visible, with both authorities left running. Verified macOS session 7c6c5e5800 / PID 82741 logs E8 profile 3C7F3831-8964-4383-8B11-185B472377FF → XYZ profile 9EBC75CA-932A-413D-B0C3-1511180ACBE8 at 20:38:44.087. Read-only lsof retains XYZ port 49986 / FD 4u / socket identifier 0x72d54417cbe25a17 and E8-associated port 49990 / FD 16u / 0x2b9df8849100957a; the messaging-associated listener is now port 49992. Return and identity/history preservation are user-confirmed PASS; original XYZ listener continuity remains observed. Final cleanup pending: stop only R1-E8-Test Authority Hosting and confirm XYZ hosting remains Running with XYZ messaging green on Mac and physical iPhone. No agent app interaction, build, source changes, staging or commit; full R1 remains open.


### Mac authority-continuity cleanup complete — November 7, 2026

User confirmed E8 hosting Stopped, XYZ hosting Running, and XYZ selected/green on Mac and physical iPhone. Read-only verification in running macOS session 7c6c5e5800 / PID 82741 shows XYZ's original listener unchanged at port 49986 / FD 4u / socket identifier 0x72d54417cbe25a17; E8-associated port 49990 is absent. Messaging listener remains port 49992. This completes the bounded Mac XYZ → E8 → XYZ messaging-switch / independent XYZ authority-service continuity phase, including restored hosting intent and user-confirmed original Mac identity/history. Scoped PASS; no exhaustive interruption timing or client signed-generation capture claimed. E14/E15 remain complete within their accepted scopes; full R1 remains open.

Next single phase: E1/E3 evidence-limit disposition. Existing cold-start/outage/recovery observations and controlled regressions are established; complete live trust-freshness-boundary soak and correlated signed-refresh/retry trace are not. Recommend explicit acceptance of existing scoped evidence with those limits retained, not recording unperformed variants as passes. No further live action requested during that decision. Remaining E2/E6/E11/E9/E13 and hosting edge-case dispositions and final build/install inventory remain outstanding separately. No source/build/app changes, staging or commit.


### E1/E3 evidence-limit disposition accepted — November 7, 2026

User explicitly answered “yes” to accepting the existing E1/E3 startup/outage/recovery and controlled-regression evidence with the missing complete live trust-freshness-boundary run and correlated signed-refresh/retry trace retained as limitations. E1/E3 acceptance is complete within that agreed scope. This is an acceptance disposition, not a new test PASS or evidence that the unperformed variants ran. E8 expired-trust activation and E14 background observations retain their distinct scopes.

Next single disposition: E2 complementary live/fixture evidence. Live generation 10 lacked the phone, admission rejection was captured, and queued recovery delivered once without Refresh by user report. Disposable HTTPS/TLS integration covers verified generation 2 → 3, admission, durable storage/acknowledgement and miss throttling. Live post-recovery generation/admission was not captured in the same run, and debugger pauses limit timing claims. Recommendation remains pending user acceptance; E1/E3 approval does not extend to E2 or other outstanding dispositions. Full R1 remains open pending those items and final build/install inventory. No live action, builds/tests, source changes, staging or commit in this documentation phase.


### E2 complementary-evidence disposition accepted — November 7, 2026

User explicitly answered “yes” to accepting E2 using the combined live rejection/single-message recovery evidence and isolated integration coverage of verified membership-generation updates and subsequent admission. E2 acceptance is COMPLETE within that agreed scope. The live recovery's post-refresh membership generation/admission was not captured in the same run, and debugger pauses prevent normal timing claims. Preserve those limits; this approval does not convert fixture evidence into a live trace or add a new test PASS.

Next single disposition: E6 resource-observation scope. Existing evidence comprises repeated functional lifecycle cycles, before/after resource observations, approximately 17-minute Mac idle stability, post-idle message delivery and 11 bounded runtime-count samples over approximately 308 seconds. These do not establish an instrumented repeated-cycle trend or account for every Swift task; the historical High energy reading remains unexplained. Recommend acceptance within that scope, pending explicit user decision. Other evidence dispositions and final build/install inventory remain outstanding; full R1 remains open. No live action, build/test, source changes, staging or commit.


### E6 resource-observation disposition accepted — November 7, 2026

User explicitly answered “yes” to accepting E6 within the recorded functional-cycle and resource-observation scope: repeated functional cycles, approximately 17-minute Mac idle stability, post-idle delivery and 11 stable bounded runtime-count samples over approximately 308 seconds. E6 acceptance is COMPLETE within that agreed scope. No instrumented resource trend across repeated cycles or complete Swift task inventory was captured, and the earlier High energy reading remains unexplained. These limitations remain explicit; acceptance does not constitute new profiling or a new test PASS.

Next single disposition: E11 configured delay/loss and recovery evidence. Messaging/UI passes under 100 ms each-way delay and, separately, 5% each-way loss, LAN ICMP observations, post-fix host-outage recovery and impairment fixtures are established. No Beakr TCP retransmission/message-ID trace or independently filtered authority-HTTPS live outage was captured; app quit affected authority and messaging together. Recommend accepting this scoped evidence with those limits and original inconclusive/failing runs retained alongside retests, pending user decision. E6 approval does not approve E11 or other outstanding items. Full R1 remains open pending remaining dispositions and final build/install inventory. No device action, build/test, source changes, staging or commit.


### E11 impairment-evidence disposition accepted — November 7, 2026

User explicitly answered “yes” to accepting E11 within the documented configured-delay/loss messaging/UI, recovery and isolated impairment-test scope. E11 acceptance is COMPLETE within that agreed scope. No Beakr TCP retransmission/message-ID trace was captured, and the live host outage interrupted both authority and messaging rather than independently filtering authority HTTPS. Original inconclusive/failing runs remain recorded alongside fixes and successful retests. This disposition adds no new test PASS or transport trace.

Next single disposition: E9 authorization evidence. Historical removal/archive/restart convergence and isolated verified HTTPS revocation, production TLS/credential rejection and unchanged receiver storage after component recreation provide complementary evidence. Live receiver rejection of a presented old credential remains unestablished. The fixture uses test-owned listener/scheduling/storage bridges and bypasses an already-rejecting resolver to exercise handshake rejection. Recommend accepting that scope explicitly, pending user decision; no live revocation, re-enrollment or archived-device access is proposed. E11 approval does not extend to E9 or other outstanding items. Full R1 remains open pending remaining dispositions and final build/install inventory. No device action, build/test, source changes, staging or commit.


### E9 authorization-evidence disposition accepted — November 7, 2026

User explicitly answered “yes” to accepting E9 on the complementary historical removal/restart and isolated revoked-credential rejection/storage-preservation evidence, retaining the missing live receiver capture and test-controlled integration limitations. E9 acceptance is COMPLETE within that agreed scope. Live rejection of a presented old credential remains unestablished. Fixture production security code uses test-owned listener/scheduling/storage bridges and bypasses an already-rejecting resolver to exercise handshake rejection. Approval adds no new live test PASS and authorizes no live revocation, re-enrollment or archived-device access.

Next single disposition: E13 creation evidence. Normal additional-network creation/activation/return passed live, and six isolated cases cover first creation and failure rollback. Clean-Mac first creation and creation-failure UI/runtime variants were NOT RUN because no spare Mac/test account is available. Recommend accepting existing evidence with those omissions explicit, pending user decision. Later hosting integration has its own component evidence; earlier live creation alone does not establish every changed lifecycle branch. E9 approval does not extend to E13, remaining hosting limitations or final inventory. Full R1 remains open. No device action, build/test, source changes, staging or commit.


### E13 creation-evidence disposition accepted — November 7, 2026

User explicitly answered “yes” to accepting E13 using the normal additional-network creation/activation/return live pass and six isolated first-create/failure-rollback cases. E13 acceptance is COMPLETE within that agreed scope. Clean-Mac first creation and creation-failure UI/runtime variants remain NOT RUN because no spare Mac/test account is available. Acceptance does not convert those omissions into passes or establish every later hosting lifecycle branch. No production profile clearing or new account is authorized or needed for this disposition.

Next single disposition: remaining independent-authority-hosting evidence limits. Scoped live start/stop, persistence, automatic endpoint recovery and Mac messaging-switch/XYZ-service continuity results stand. Delayed administration completing after UI selection changes and occupied-port/failure UI scenarios remain fixture/limited evidence rather than established full live UI passes. Recommend accepting hosting within the recorded evidence scope with those limitations explicit, pending user decision. No exhaustive interruption timing/client signed-generation capture is claimed for the continuity run. Final common source/build/install inventory and bounded validation remain outstanding; full R1 is open. No device action, build/test, source changes, staging or commit.


### Independent-hosting disposition accepted; final Mac build — November 7, 2026

User explicitly answered “yes” to accepting independent hosting within its recorded live/component evidence scope, retaining delayed-administration completion after UI selection changes and occupied-port/startup-failure UI scenarios as lacking full live UI verification. Hosting acceptance is COMPLETE within that agreed scope; this does not turn unperformed variants into passes. Full R1 remains open for final source/build/install validation.

Final inventory preparation compared all 269 source/config manifest entries and current eligible Git-listed paths: no changed, added or removed entries relative to /tmp/Beakr-R1-source-inventory-20261107.json (SHA-256 d81649d55370f6b7e5b0ed5e45ea8819a40e1dab7ea09f0fe1d58c98c9c53d61). Existing manifest scope excludes documentation/assets and is not a complete build-input fingerprint. No source edits since the 19:58 isolated inactive-name regression; no repeat of that passed test warranted.

Xcode verified Beakr / My Mac active. BuildProject passed at 20:48 with no reported errors; BuildProject-Log-20261107-204819.txt in ActionArtifacts/FDF24040-C162-41A6-998B-799DE54A413E/BuildProject. Build reason: final Mac compilation of the later shared Friendly Name preference-injection change, previously only built/tested for baseline. No Mac launch/stop or other automated app interaction performed. Built executable SHA-256 bd7236ec402265942e575062e63515219926e26598a68769175c3cfd77d0b8a2; Beakr.debug.dylib SHA-256 7d5d9312952ea2270a7da324cde8031dea2cffd36d2e996c05c45ad8c44f9f1c. Paths recorded in /tmp/Beakr-R1-Mac-build-inventory-20261107.json. These identify on-disk build outputs, not the still-running older process or every app-bundle resource.

Next single phase: user confirms Conditioner still OFF and runs this final Mac build via Xcode My Mac, then confirms original Mac name/XYZ Node ID suffix A98/history, XYZ messaging green, XYZ hosting Running and E8 hosting Stopped. This is a bounded final-build preservation/startup check, not a repeat of full E14 or the authority-switch exercise. Physical-iPhone/original-simulator final build/install inventory remains subsequent work. No stage/reset/commit; existing workspace preserved.


### Final Mac build — UI confirmation received, new launch still pending, November 7, 2026

User replied “confirmed” to Conditioner OFF and the requested Mac state checks: XYZ green/history visible, original MacMini-Ice-9 name, XYZ node suffix A98, XYZ hosting Running and E8 hosting Stopped. Record those as user-confirmed state. Independent launch verification does not establish execution of the final 20:48 build: GetConsoleOutput still returns macOS session 7c6c5e5800 / PID 82741, and read-only pgrep/ps identifies that same sole Mac Beakr process with start time November 7 18:53:45. Its console sender image UUID remains D5AB9104-A17B-3A96-B977-BAD78D8BECE4. Therefore do not mark final-build deployment/startup PASS from the UI confirmation alone.

Xcode remains Beakr / My Mac. Next single step: user Run via Xcode My Mac (replace the already-running instance if prompted), then report app reopened. Agent will verify new Mac session/PID before proceeding with final startup/state confirmation. Physical-iPhone build has not yet been performed in this phase; no destination switch, app interaction, build/test or source change by agent. No full E14/E15 rerun requested. Full R1 remains open; existing acceptance dispositions stand. Workspace/index preserved, no staging/reset/commit.


### Final Mac binary launch verified — November 7, 2026

After the user reported Beakr reopened, console verification identifies running macOS session 7c79669800 / PID 94021, with sender path Debug/Beakr.app/Contents/MacOS/Beakr.debug.dylib and image UUID 690BF0C8-BE6D-34BD-B9E3-B37CC2B7D214. Read-only process listing shows the new Mac PID; prior PID 82741 no longer appears. Both executable and debug-library hashes still match /tmp/Beakr-R1-Mac-build-inventory-20261107.json from the 20:48 BuildProject. dwarfdump confirms the on-disk debug-library UUID matches the new console sender UUID. This verifies launch of the recorded final Mac build, rather than inferring it from unchanged UI values. A follow-up ps start-time query was sandbox-denied; no exact process-start timestamp is claimed.

Final post-launch UI preservation confirmation remains the next single step: original MacMini-Ice-9 name / XYZ node suffix A98 / existing XYZ messages, green XYZ messaging, XYZ hosting Running and E8 hosting Stopped. Earlier UI confirmation applied to the prior process and is not silently transferred to this launch. No additional rename, switch or outage exercise requested. Remaining physical-iPhone/original-simulator build/install validation and final signoff stay open. No source changes, build/test, automated app interaction, staging or commit in this verification phase.


### Final Mac startup PASS; physical-iPhone build ready — November 7, 2026

User confirmed the requested post-launch checks on verified final Mac process 94021 / session 7c79669800: XYZ green and existing messages visible, MacMini-Ice-9 name, XYZ node suffix A98, XYZ hosting Running and E8 hosting Stopped. Final Mac build/startup preservation check is user-confirmed PASS with binary/session verification recorded above. No full rename/switch acceptance rerun performed.

Xcode destination inventory identifies physical 360-iPhone-Dev / iOS 27.2 / arm64. Selected that destination for Beakr and ran Xcode BuildProject: PASS, no reported errors, BuildProject-Log-20261107-205302.txt under ActionArtifacts/FDF24040-C162-41A6-998B-799DE54A413E/BuildProject. Purpose: compile final shared-source changes for physical iPhone; previous phone deployment predated them. All 269 recorded source/config entries still match the final source manifest. On-disk executable SHA-256 e0a6b7f63dc3fbbcd956abc7b58f0db5f1b069c7d55e79331f30409163c52805 / UUID 29588FF4-6665-352B-975D-1B1E669D217A; debug library SHA-256 6b7964e46e36e03de136c4caf610e1633c5f14c8c5d27e3c30f94f087e64c053 / UUID 1B80CB8D-13AC-3CE6-945B-04EB67B15FBD. Paths captured in /tmp/Beakr-R1-iPhone-build-inventory-20261107.json. On-disk build identity is not yet installed/running phone verification.

Next single step: user Run with 360-iPhone-Dev selected, then report reopened app and XYZ green, original iPhone-Dev-T1 name, XYZ node suffix C0B3 and existing message history. Conditioner last reconfirmed OFF during final Mac startup; no impairment change requested. Agent has not installed/launched/interacted with the physical phone. Verify returned console platform/session/PID and loaded image before claiming installed final binary. Original iPhone 17 simulator final inventory remains subsequent work; full R1 open. No source edits, staging/reset/commit; existing workspace/index preserved.


### Final physical-iPhone startup PASS; original simulator build ready — November 7, 2026

User confirmed final phone Run/reopen, XYZ green with existing messages, original iPhone-Dev-T1 name and XYZ Node ID suffix C0B3. Console independently verifies running session 7c6c543300 / PID 7849, physical-device bundle path /private/var/containers/Bundle/Application/3E9B006E-388A-45BC-8E83-9D9DBF6FBE3B/Beakr.app/Beakr.debug.dylib, loaded UUID 1B80CB8D-13AC-3CE6-945B-04EB67B15FBD matching the final 20:53 phone build. Active destination was 360-iPhone-Dev / iOS 27.2. At 20:54:14 console reports active green / connected(peerCount: 1). Final phone build/startup preservation check PASS within this scope; no new full messaging/rename acceptance exercise.

Selected the discovered original iPhone 17 (27.0) Xcode destination and ran BuildProject, PASS with no reported errors: BuildProject-Log-20261107-205446.txt under ActionArtifacts/FDF24040-C162-41A6-998B-799DE54A413E/BuildProject. This builds final source for the remaining original live acceptance participant, whose earlier installed build predates shared-source changes. No simulator install/launch/touch performed by agent. User-operated Run is next, specifically iPhone 17 (27.0), not the separate 27.2 instance.

Simulator build inventory /tmp/Beakr-R1-Simulator-build-inventory-20261107.json records executable SHA-256 8e1705b898d13f0b2e4891386c1453d2900640e483cf6205d2be8da479da31a9 / UUID A5B78E3F-0BBB-384A-AB5E-259A91A3E96F and debug-library SHA-256 575e0256c4853a1ce0931b4e0c7da21e5a2dedf4875732dc9d935700db26bde5 / UUID CAFB8B47-D2CB-3581-A4A1-E7110AD97C5A. These are on-disk outputs, not installed simulator verification. Next user confirmation: reopened original simulator, XYZ green, original iPhone-17 name, XYZ Node ID suffix 629 and existing messages. Verify console platform/session/PID and simulator identity after Run. No source edits, stage/reset/commit; full R1 remains open pending final inventory/signoff.


### Final simulator verification and R1 signoff readiness — November 7, 2026

User confirmed final original iPhone 17 (27.0) startup: XYZ green, existing messages visible, original iPhone-17 name and XYZ Node ID suffix 629. Console verifies running session 7c7a2f2580 / PID 94716; sender path explicitly identifies original simulator DE26C44E-C798-4645-B26C-FF891A09F71F and loaded debug-library UUID CAFB8B47-D2CB-3581-A4A1-E7110AD97C5A matching the final simulator build. At 20:56:22 the console reports active green / connected(peerCount: 2). This is the original 27.0 simulator, not the separate 27.2 instance. Final simulator build/startup preservation check PASS within this scope.

All three live final participants now have successful Xcode BuildProject results, user-operated launch, loaded-library UUID verification and user-confirmed original name/node/history/green XYZ state: Mac (20:48 build, PID 94021, session 7c79669800), physical iPhone-Dev (20:53 build, PID 7849, session 7c6c543300), original iPhone 17 (20:54 build, PID 94716, session 7c7a2f2580). These are recorded verification sessions, not a promise that PIDs remain current. Mac hosting intent was confirmed XYZ Running / E8 Stopped after final Mac launch. Latest active Xcode destination is iPhone 17 (27.0).

Final source/config inventory comparison: all 269 recorded entries unchanged, no added/removed eligible Git-listed paths, manifest SHA-256 d81649d55370f6b7e5b0ed5e45ea8819a40e1dab7ea09f0fe1d58c98c9c53d61. All six recorded executable/debug-library hashes still match on-disk Mac/phone/simulator build outputs. Inventory scope excludes documentation/assets and does not certify every bundle resource or excluded device. Final fingerprints are transcribed in this record/audit; temporary JSON inventories remain under /tmp. Existing 19:58 authorized-baseline inactive-save regression passed 1/1 on the unchanged source; no reason to repeat it or earlier full live passes. This is bounded final validation, not a new full-suite or final-build roundtrip claim.

Consolidated recommendation: R1 is READY FOR FINAL USER SIGNOFF within the documented scope. E1/E3, E2, E6, E11, E9, E13 and remaining hosting evidence-limit dispositions were individually approved; E14/E15 and earlier scoped case results stand. Mac authority continuity and cleanup passed, and final participant build/startup inventory is complete. All unperformed variants, fixture boundaries, timing/telemetry gaps and historical failures remain explicit. No new functional blocker found in this reconciliation. Original A-Series checklist is unavailable, so readiness concerns the documented R1 scope only.

Final overall acceptance has not yet been requested/received at this recording point; do not infer it from the latest simulator confirmation. Next single step: user accepts final scoped R1 signoff. Concurrent multi-network messaging/presence and Host/Co-Host remain future work; authority-icon feature request and Device Hub shortcuts remain separate follow-ups. Protected identities/history and excluded iPhone 18 Pro remain untouched. No stage/reset/commit; no agent nonbaseline app interactions.


### R1 FINAL ACCEPTANCE — user-approved November 7, 2026

User explicitly answered “yes” to “Do you accept R1 complete within that documented scope?” R1 is COMPLETE AND ACCEPTED within the documented scope and individually approved evidence limitations. This final acceptance supersedes earlier open/ready/pending-signoff statements; those dated records remain historical. No unperformed variant is reclassified as a test PASS, and no broader product scope is implied.

Basis: recorded E1–E15 scoped evidence and explicit dispositions; independent per-network authority hosting/dynamic endpoint recovery and Mac messaging-switch continuity; completed final Mac, physical iPhone-Dev and original iPhone 17 (iOS 27.0) Xcode builds, loaded-build verification and user-confirmed name/node/history/green startup checks. The unchanged-source baseline regression remains PASS 1/1; no new full-suite or final-build roundtrip claim. Source/config manifest and executable/library fingerprints are recorded in the final inventory, with their exclusions retained.

Final confirmed state: Mac and physical iPhone use XYZ; original iPhone 17 also XYZ green. Original names/identities/history retained. Mac XYZ authority Running, R1-E8-Test authority Stopped. Conditioner last reconfirmed OFF. Xcode destination remains iPhone 17 (27.0). No further R1 action pending under this acceptance; no new phase started.

Separate follow-ups remain outside accepted R1: authority hosting-state icon/visibility request; Device Hub Command-A/Command-V shortcuts; future simultaneous multi-network messaging/presence and Host/Co-Host service-role design. Protected iPhone 18 Pro and all preserved memberships/profiles/history remain untouched. This acceptance does not authorize staging, commits, deployment/publication or broader feature work. Documentation-only recording; workspace/index changes preserved, no reset/stage/commit.

### November 9 — approved network colour presentation follow-up

This supersedes earlier colour expectations without changing recorded R1 test outcomes. Healthy ready-with-no-peers and connected networks are green; startup/reconnecting/discovery blue; selected network unavailable/failed/permission denied red; unselected networks grey. Peer counts remain separate. Authority hosting is independently blue when running.

Focused visual check (pending): on each platform, a healthy selected network with no other online Beakr devices settles to green after the existing discovery interval and reports 1 Device Online; adding a peer updates the count while staying green. Connection failure or permission denial remains red. Inactive saved networks remain grey. This presentation check does not reopen completed R1 acceptance.
