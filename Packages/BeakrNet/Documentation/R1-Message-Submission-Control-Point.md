# R1 Message Submission Control Point

Initial characterization, October 26, 2026. This maps current code to the proposed logical Node responsibilities. It does not introduce a new Node identity, Actor permission schema, or audit system. Existing working-tree changes are part of the inspected baseline.

## Current status — end of October 26, 2026

The user completed the repaired Mac/iPhone restart scenario: shutting down either app leaves the other blue (ready with no connected peer); restarting the peer restores both to green without Refresh. This specific hands-on scenario passes. Earlier pending/failing statements below are retained as investigation history, not the latest result. Broader R1 acceptance is not declared complete.

Current repair validation: 47/47 application tests and 13 focused discovery/membership tests passed. The earlier complete package baseline was 342 passed, 0 failed, 3 skipped; the complete package suite was not rerun after this recovery repair. The three opt-in integrations and seven signed simulator integration tests passed in earlier separate runs.

Today's discussion, observations, conclusions, and next-session instructions are saved in R1-Recovery-Session-2026-10-26.md and Beakr-Startup-2026-10-27.md. The printable companion to this document is R1-Message-Submission-Control-Point.pdf.

## Current execution path

| Step | Existing owner | Observed responsibility |
| --- | --- | --- |
| Composition | Apps/Beakr/MessageComposerModel.swift, send() | Validates destination presence and nonempty trimmed text; creates correlation identity and a provisional sending row. |
| Local history | MessageComposerModel, persistMailboxMetadata() | Saves Context mailbox metadata. Failure is exposed through mailboxPersistenceError but does not throw or prevent submission. This is not an audit admission gate. |
| Runtime entry | Apps/Beakr/ApplicationLANRuntimeManager.swift, sendWithProvenance() | Requires a configured messaging service and provenance context, invokes it, and returns provenance from the exact envelope. |
| Network context | ApplicationLANRuntimeManager.start() contextProvider closure | Captures the selected runtime profile and membership directory, obtains a connection session and sequence number, and supplies Network ID and source Node ID. The caller cannot substitute a Network ID in HostMessageRequest. |
| Envelope and durable queue | Packages/BeakrNet/Sources/BeakrNetHost/PersistentHostMessagingService.swift | Encodes a Data envelope and calls PersistentDataState.enqueue before attempting submission. |
| Persistence | Packages/BeakrNet/Sources/BeakrNetData/DataPersistence.swift | Validates channel/envelope, enforces capacity, and atomically replaces the queue snapshot file. Failed enqueue now rolls back its in-memory admission before returning the error. |
| Dispatch | Packages/BeakrNet/Sources/BeakrNetHost/ProfileConnectionRegistry.swift, submit() | Uses a registered peer driver. Missing route and delivery errors become routeUnavailable; the queue is retained. |
| Presentation | MessageComposerModel.send() | After service return, chooses sent or queued using observed online-recipient presence. Sent is not proof of delivery. |
| Delivery confirmation | ApplicationLANRuntimeManager.start() acknowledgement sink | Resolves correlation from pending work, removes the acknowledged envelope, and reports delivered when removal succeeds. |

The current caller is established through application composition; there is no general authenticated User/Actor context or mandatory Actor audit journal on this path. OutgoingMessageProvenance is diagnostic attribution, not evidence of the proposed delegated authorization model.

## Authenticated peer lifecycle notice — October 27, 2026

Application backgrounding now attempts to send an ephemeral typed Control message before LAN routes are disabled. `beakrnet.peer-lifecycle` carries state `suspending` and a bounded reason (`applicationBackgrounded`, `applicationTerminating`, `networkTransition`, or `runtimeStopping`). The production background path currently sends `applicationBackgrounded`; ordinary runtime stops use `runtimeStopping`.

The notice is accepted only through an already authenticated session and is consumed by the Host Control boundary rather than delivered to the application mailbox. It is advisory presence information: it does not revoke membership, authorize work, claim delivery, or replace transport path-loss handling. The sender does not wait indefinitely for receipt. Abrupt termination, suspension before the asynchronous send completes, power loss, and network loss may still produce a reset or timeout without a notice.

The sender logs the attempted reason and submitted peer count before disabling routes. The receiver logs the authenticated peer Node ID, lifecycle state, and reason. Application diagnostics begin with `[iOS]` or `[macOS]`, followed by the Beakr subsystem such as `[Beakr Runtime]`; the `start=` field correlates events with the runtime invocation without implying that every event is a startup event.

Focused verification passed all 9 BeakrNetControlTests and all 13 HostServicesTests. The Host test proves that an authenticated lifecycle notice is handled as Control and never reaches application Data. The Beakr application build-for-testing succeeded and all 47 BeakrTests passed. The combined Xcode plan also ran two UI tests: launch performance passed, while `testMailStyleShellProvidesToolbarWindowsAndDialogs` failed an existing shell assertion. No complete package suite was run for this change.

## Existing authorization boundaries

ProfileMembershipDirectory verifies signed membership snapshots and resolves currently valid, non-revoked credentials. The context provider obtains a pair session through connectionSessionID. Registered peer drivers provide the transport execution boundary. Per-Actor permissions remain unimplemented; they must not be inferred from current Node membership.

Focused characterization confirmed that connectionSessionID previously validated only the canonically selected session owner. The correction validates both endpoints through sessionID(for:) before returning the same canonical session. Tests cover missing, revoked, and expired membership on either side and both caller/peer orientations. This closes a pair-eligibility gap; it does not establish per-Actor authorization or imply that unauthorized transport delivery previously succeeded.

## Outcomes and interrupted work

| Situation | Current observation | Contract implication |
| --- | --- | --- |
| Invalid composer input | No Service request. | Rejection before queue admission. |
| Context provider fails | No envelope enqueue by PersistentHostMessagingService. | Admission failure. |
| Durable enqueue succeeds and route is unavailable | Service returns; envelope remains queued. | Accepted is distinct from dispatched or delivered. |
| Generic submit closure throws after enqueue | Public service method throws although durable work remains. | A generic failure cannot safely be interpreted as no accepted work. The current application closure is nonthrowing and maps errors to routeUnavailable. |
| Queue persistence throws | Enqueue now removes its provisional in-memory admission before rethrowing. | Rejected work is neither pending nor silently included in a later save; an explicit retry may succeed once storage recovers. |
| Metadata persistence fails | UI records an error but may continue sending. | Metadata is not the authoritative delivery queue or a mandatory audit gate. |
| Retry pending | Reuses stored envelopes and does not request a fresh delivery context. | Stable identity is preserved; dispatch eligibility must remain enforced downstream. |
| Acknowledgement observed | Queue removal and delivery update are attempted. | Record only the protocol's delivery guarantee, not remote application execution or reading. |

## State and ownership rules to preserve

1. Context history remains independent of membership removal.
2. Durable queue acceptance, route submission, delivery acknowledgement, and read receipt remain distinct facts.
3. An existing envelope retains its network and message identity during retry.
4. A stopped or replaced runtime must not revive through late work; characterize transitions across await points before extraction.
5. New permission or audit gates require defined evidence, persistence failure behavior, and recovery. This characterization does not claim those gates exist today.

## Existing test anchors

| Suite | Existing tests | Scope |
| --- | --- | --- |
| BeakrTests | queueMessage, sendOnlineMessage, invalidDestination, hostFailure | Composer behavior with injected messaging services. |
| BeakrTests | mailboxMetadataIsContextScoped, forgettingPreservesContextMessageStore | Metadata isolation and retained Context data. |
| PersistentHostMessagingServiceTests | offlineQueueAndRetry, cancellation | Offline durability, unchanged retry envelopes, correlated cancellation. |
| DataPersistenceTests | failedEnqueueIsNotAccepted | Write failure, repeated failed admission, preservation of previously accepted work, later unrelated save/reopen, and explicit retry after recovery. |
| ProfileMembershipDirectoryTests | bothEndpointsMustBeEligible | Six parameter cases covering missing/revoked/expired membership at either canonical position; each checks both caller orientations. |

Missing or uncertain cases should become focused behavioral tests before a repair or extraction. Do not add tests that merely mirror a new wrapper.

## Baseline execution

The Xcode tool bridge returned IDEKit.IDEStatefulActionError error 0 for read, test discovery, and build-for-testing. A sandboxed command-line attempt also failed. Command-line Xcode access outside that sandbox successfully discovered destinations.

A dedicated simulator was created to keep the test host away from existing application data: Beakr-R1-Contract-Baseline-20261026, iPhone 17 / iOS 27.0, ID E40CDB24-C697-4F57-8F87-CBFD9DFADDD5. The Beakr scheme ran only the BeakrTests target, with parallel testing disabled. This is an iOS Simulator baseline, not a Mac/iPhone hands-on or package-suite result.

Artifacts are retained in /private/tmp/Beakr-R1-Contract-Baseline-20261026.log, /private/tmp/Beakr-R1-Contract-Baseline-20261026.xcresult, and the matching derived-data directory. The simulator and test artifacts are not deleted.

### Results and fixture repair

The initial run reproduced 36 passed and 9 failed (30 failed expectations). The failures were authorityConfiguration, configuredNetworkWithoutLocalNetworkIsInactive, trustRecovery, preparedLifecycleBypassesLegacyMigration, persistedLifecycleRouteGatesMessaging, sharedNetworkRenamePreservesIdentityAndConnectivity, foregroundRetriesFailedLANStartup, createNetwork, and createAdditionalNetwork.

The SuccessfulTrustBootstrapper test double did nothing. Production bootstrap now loads and verifies revocation and membership snapshots before routing enrollment or starting messaging, so those tests stopped before reaching the behavior they intended to exercise.

The repair is confined to Apps/BeakrTests/BeakrTests.swift. Tests needing successful trust recovery now inject SignedFixtureTrustBootstrapper with their own CredentialAuthority. It writes canonical signed membership evidence using the configured credential and an authority-signed empty revocation snapshot to the test runtime's isolated trust directory. Earlier-stage tests retain an explicitly named NoopTrustBootstrapper. No production verification, UI behavior, credentials, or schema was changed.

The complete BeakrTests target was rerun after repair: **45 passed, 0 failed**, with xcodebuild reporting TEST SUCCEEDED. Results are retained in /private/tmp/Beakr-R1-Signed-Fixtures-20261026.xcresult and /private/tmp/Beakr-R1-Signed-Fixtures-20261026.log. The run used the same isolated simulator and derived-data directory. This result supersedes the historical 36/9 result for this target and destination only; UI, package, physical-device, and macOS runs remain unverified in this work.

Existing Swift concurrency warnings about main-actor-isolated Equatable conformances were present during the build. They did not fail this run and are not repaired by the fixture change.

## Boundary corrections and regression validation

Both targeted defects were reproduced before their corrections. Failed queue admission remained pending, a repeat enqueue incorrectly returned success, and later persistence could include rejected work. Pair session lookup accepted an ineligible lower-ordered participant when the higher-ordered participant remained eligible.

The corrections are limited to enqueue rollback in PersistentDataState and both-endpoint validation in ProfileMembershipDirectory. No new identities, schema, wire format, Actor runtime, or audit framework were introduced. The expiry test advances beyond the existing 60-second clock-skew allowance; that policy is unchanged. Other persistence mutations and post-enqueue submit failures are not claimed to have been corrected here.

Focused verification passed: six DataPersistenceTests and five tests across ProfileMembershipDirectoryTests and PersistentHostMessagingServiceTests, including all six parameter cases. The complete BeakrTests target again passed 45/45 on the dedicated iOS simulator. The Xcode tool bridge remained unavailable; command-line Xcode produced a successful build/test report.

The initial complete package run reported failures in PersistentEnrollmentStoreTests.authorityStatePersistence (audit/request pruning expectations) and CertificateEnrollmentTests.wrongKey (expected invalidSignature but received nodeIdentityMismatch). Both failures reproduced in a separate copy of the current package with the two production corrections removed, confirming that they predated these boundary corrections. No shared working-tree files were reverted for that comparison. The subsequent fixture corrections and passing baseline are recorded below.

Evidence is retained under /private/tmp: Beakr-R1-Boundary-Red.log, Beakr-R1-Boundary-Verified.log, Beakr-R1-Boundary-Package.log, Beakr-R1-Boundary-App.log, Beakr-R1-Boundary-App.xcresult, and Beakr-R1-Boundary-Unchanged-Failures.log. The comparison source snapshot is Beakr-R1-Boundary-Before-vzwtja26. Existing test/application data and staged changes were preserved.

## Enrollment fixture corrections and current package baseline

Both remaining failures were caused by test setup or expectations, not by a need to weaken production checks:

- CertificateEnrollmentTests.wrongKey reconstructed a request without its certificate signing request bytes. Identity validation correctly rejected the incomplete request before signature verification. The corrected test preserves the original CSR and changes only the signature. It also verifies that rejection does not consume the challenge: the legitimate request subsequently validates.
- PersistentEnrollmentStoreTests.authorityStatePersistence expected approved enrollment to be prunable. Approved enrollment is intentionally nonterminal until installation is confirmed. The test now verifies retention through pruning and reopen while approved, persists a signed installation confirmation, reopens to verify confirmed status, and only then checks terminal pruning.

No production code changed in this follow-up. The focused run passed 19 test functions across the selected suites. The complete package suite was then rerun with swift test --disable-sandbox: **342 passed, 0 failed, 3 skipped**, counted by test functions (parameterized cases are additional executions). The skipped tests are the explicitly opt-in Apple Network, authority HTTPS, and OpenSSL certificate integration tests. Logs are /private/tmp/Beakr-R1-Enrollment-Fixtures-Focused.log and /private/tmp/Beakr-R1-Enrollment-Fixtures-Package.log.

The latest application result remains 45/45 passing on the dedicated iOS simulator from the preceding boundary-correction run. Application tests were not rerun for these package-test-only edits. Neither baseline establishes physical Mac/iPhone behavior or results for the skipped integration layers.

## Opt-in integration and simulator checks

The three previously skipped package integration tests were explicitly enabled and passed in separate runs: Apple Network discovery/TLS/authenticated handshake/framing/path-loss diagnostics (one test), OpenSSL certificate issuance (one test), and authority HTTPS enrollment/membership/revocation (one test). These supplement the 342-pass package baseline; they are not a new complete-suite run. Logs are /private/tmp/Beakr-R1-Apple-Network-Integration.log and /private/tmp/Beakr-R1-Certificate-HTTPS-Integration.log.

The signed integration host initially failed to compile because two ValidatedCertificateEnrollment fixtures omitted the required certificateSigningRequestDER. Apps/BeakrNetIntegrationTests/SignedLANIntegrationTests.swift now passes the corresponding signed request's CSR for initial enrollment and renewal. No production API or validation was changed.

After that fixture repair, the signed host passed **7 tests in 2 suites** on the dedicated iOS simulator, with TEST SUCCEEDED. This covers host configuration and six signed LAN integration tests, including mutual TLS, invalid-peer rejection, Keychain replacement, and enrollment restoration/renewal. The harness used disposable credentials and a temporary project copy so fixture injection did not modify the repository test plan. Evidence: /private/tmp/Beakr-R1-Signed-Simulator-Retry.log and /private/tmp/Beakr-R1-Signed-Simulator-Retry.xcresult. The initial compile-failure evidence remains in /private/tmp/Beakr-R1-Signed-Simulator.log and its matching result bundle.

A read-only simulator UI check activated the existing Beakr installation and confirmed the No Networks screen, Switch Network: Inactive accessibility state, and Message activity: Idle. No visible errors, overlap, or truncation were observed. No controls were tapped or network/settings data changed. The device interaction bridge worked even though the workspace-backed Xcode tools had failed earlier. This check establishes empty-state rendering only.

Hamilton/Queens hands-on acceptance remains outstanding: switching between configured networks, reconnecting after restart, and checking message routing and retained Context history on the Mac/iPhone pair. Removal and revocation scenarios require an agreed disposable network or membership to preserve existing test data. The signed simulator results do not establish physical-device or signed macOS-host behavior.

## Next bounded implementation decision

### Peer-loss recovery repair

The captured iPhone trace establishes this sequence: at 1793068292.534 the Mac connection closes; the application schedules a full local restart; shutdown completes; startup waits for trust refresh from the unavailable authority; at 1793068300.603 the eight-second startup deadline cancels that work and sets failed. At 1793068301.727 periodic member reconciliation overwrites failed with inactive because shutdown cleared local availability. Discovery never restarted. This accounts for grey, red, then persistent grey without requiring an unproven concurrency race.

The focused repair removes the application-level full restart on loss of the last authenticated peer. The existing Bonjour coordinator remains responsible for connection retries and returning advertisements; listener, browser, and trust maintenance remain running. No membership or revocation validation is bypassed. Manual Refresh retains its existing restart/reconciliation behavior. Routine peer updates no longer replace reconnecting or failed states, and NetworkSession exposes Last Error when connectivity is failed even if bootstrap state remains ready.

Two new application regressions reproduced nine failed expectations before the repair: peer loss caused another start/stop and prevented return without restart; a forced restart timeout lost both failed status and Last Error during member reconciliation. After the repair the complete application target passed 47/47 on the isolated simulator, including successful explicit recovery after the timeout. Evidence: /private/tmp/Beakr-R1-Peer-Recovery-Red.log and /private/tmp/Beakr-R1-Peer-Recovery-Green.log with matching xcresult bundles.

Supporting discovery tests initially failed because fixed task-yield counts did not ensure callbacks had executed before assertions or failure injection. Three affected tests now use bounded waits for observable events; the retry test also waits for the coordinator to finish installing the connection handler. Production package code was unchanged. Focused verification passed 13 test functions across discovery and membership suites (including six parameter cases in the membership eligibility test). Evidence: /private/tmp/Beakr-R1-Peer-Recovery-Package-Verified.log; the initial failures are retained in the Package and Package-Retry logs with the same prefix. The complete package suite was not rerun for this repair.

Before user confirmation, physical acceptance was pending with this procedure: rebuild both apps, establish green, stop either peer, and verify the remaining app stays ready with no peers rather than restarting against an unavailable authority. Restart the stopped peer and verify automatic authentication returns green without Refresh. Preserve Hamilton and Queens memberships and Context data. Diagnostic logging remains available for any failure.

### Hamilton restart recovery failure reported during hands-on testing

The user reports Hamilton selected on both Mac and iPhone, with matching displayed Network ID suffix 7F7. Initially both were blue with no visible Last Error; iPhone Refresh did not recover connectivity, while Mac Refresh did. From a connected (green) pair, restarting the iPhone recovered green while the Mac remained running. Restarting the Mac instead left the Mac blue and the iPhone grey, unchanged after two to three minutes without manual refresh. These are user-observed results, not an automated reproduction. Full IDs, expanded status text, and live logs have not yet been captured.

Code inspection shows that losing the last authenticated peer schedules a full local runtime restart. Grey represents either inactive or reconnecting; the colour alone cannot identify which state is stuck. The eight-second deadline in startLANRuntimeWithinDeadline covers the start call, but excludes the preceding stop and subsequent localNetworkAvailable probe. The probe cancels its NWPathMonitor on task cancellation without explicitly resolving its checked continuation. These are investigation targets, not established causes of this incident. Xcode GetConsoleOutput failed with IDEKit.IDEStatefulActionError error 0, preventing direct examination of the current launch logs.

R1 restart recovery acceptance therefore remains failing. Preserve the Hamilton profiles and Context data while diagnosing; duplicate invitation rejection is not a repair mechanism for this connection failure.

Later user observations broadened the failure: restarting either device can recover automatically or leave the pair disconnected, and manual Refresh on either device has restored green in different runs. One Mac shutdown/restart sequence left the iPhone grey, then red as the Mac returned, then grey indefinitely; iPhone Refresh restored both. Screenshots show Hamilton selected, This Device Offline, zero other online/known-offline devices, and a green local-device dot on the main screen despite the offline detail view. No membership loss is established by these observations. Timing is suspected but the underlying race has not been reproduced in automation.

Recovery instrumentation was added to NodeBootstrapModel and ApplicationLANRuntimeManager without changing recovery policy. Console records include wall-clock timestamps, monotonic uptime, profile identifiers, runtime generations, reconnect/transition/start identifiers, cancellation state, and entry/exit milestones for shutdown, startup, trust refresh, discovery/listener startup, pending-message retry, and local path probing. Existing Bonjour, transport, and runtime events are correlated with the start identifier. Bootstrap and connectivity writes, peer updates, lifecycle events, manual refresh, and coalesced requests are recorded. These are operational diagnostics, not the proposed Actor audit journal; message payloads, invitations, and credentials are not added to the trace.

Validation: the diagnostic build passed all 45 BeakrTests on the isolated iOS simulator. Evidence is /private/tmp/Beakr-R1-Recovery-Diagnostics.log and /private/tmp/Beakr-R1-Recovery-Diagnostics.xcresult. BuildProject again failed through the Xcode bridge; command-line xcodebuild completed successfully. No diagnostic build has been installed on the physical iPhone or launched over the user's current Mac session in this step.

Next capture: build/run the updated app on the Mac and iPhone with console capture, establish green, restart one side, preserve the automatic failure trace, then press Refresh once on the remaining disconnected side and retain the recovery trace. Filter for Beakr Recovery, Beakr Runtime Start, Beakr Runtime Stop, and Beakr Trust. Record which device was restarted and refreshed. Compare the last completed milestone and generation on the failed path against the successful manual path before choosing a production repair. Keep the existing Hamilton and Queens profiles and data.

The automated package, application, opt-in package integration, and signed simulator checks are passing within the scopes recorded above. Next establish Hamilton/Queens hands-on acceptance evidence before declaring R1 stable. Identity mapping, Service ownership, and mandatory audit conditions remain design gates for architectural extraction. Current production changes enforce existing admission requirements; they are not implementation of a general Node runtime.
