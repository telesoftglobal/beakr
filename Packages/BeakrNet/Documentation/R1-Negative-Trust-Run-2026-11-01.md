# R1 negative-trust run specification and build inventory

Prepared November 1, 2026. **NOT RUN.** This specifies the next bounded integration work; it does not certify installed builds or replace physical acceptance.

## Read-only inventory

- HEAD: `9830e3d02724515ed058a55c6146e1c5316b3409`; substantial staged, unstaged and untracked work means HEAD alone is not the tested source.
- Source/config manifest: `/private/tmp/Beakr-R1-source-inventory-20261101.json`, 251 entries. SHA-256: `7352adf9b49d23dfef25a2eb0d79165f18ef533019e6386b8c026cec869cd7d5`. It hashes Git-listed tracked/nonignored untracked source and build configuration under Apps, Packages and Scripts, including working-tree deletions. It is not a complete asset/build-input manifest or installed-binary identity.
- Index binary-diff SHA-256: `a03324d514e31584080d242fac380bfd1de41e2fe825b5aa1625e63306297a3c`.
- Working-tree binary-diff SHA-256 before this documentation append: `211a236e07c965e600699f0b662f8e6649f07ef178c84f47e5ae8c3f42105421`. Documentation edits subsequently change this fingerprint; the source/config manifest excludes documentation.
- Xcode active scheme/destination: **Beakr / My Mac**, unchanged. Host `sw_vers`: macOS 27.0, build 26A428.

| Participant | Xcode reported OS | Installed-code evidence |
| --- | --- | --- |
| Mac authority on XYZ | macOS 27.0 | User ran updated Mac for persistence smoke and latest Forward retest. Exact running binary UUID not captured. |
| 360-iPhone-Dev | iOS 27.2; destination SDK iOS 27.1 | User ran updated persistence/draft fixes and passed phone smoke. Later shared ContentView changes not confirmed installed. |
| iPhone 17 | Simulator iOS 27.0 | Installed source revision unverified. |
| iPhone 17 Pro | Simulator iOS 27.0 | Earlier navigation/Reply and messaging passes; latest persistence change installation unverified. |
| iPhone 17 Pro Max | Simulator iOS 27.0 | Enrollment/message evidence; latest installed revision unverified. |
| Beakr-R1-Contract-Baseline-20261026 | Simulator iOS 27.0 | Only authorized automated app-test destination; no run in this preparation. |
| iPhone 18 Pro | Simulator iOS 27.0 in destination listing | Protected archived participant. No inspection of its app, reset, cleanup or re-enrollment. |

Destination availability does not establish a running app or its build. `simctl list devices booted -j` failed to access CoreSimulator services in the sandbox; no service restart, escalation or device mutation followed. Exact simulator identifiers and installed app UUIDs remain unconfirmed. They must be recorded before any later device run; names alone must not select a disposable participant.

## Concrete gap to close

Existing `ProductionLANTLSIntegrationTests.combinedCredentialAdmission` proves production mutual TLS, signed Beakr credential rejection and persistent-store exclusion, but installs signed revocation evidence directly and uses a test-owned storage bridge. `ProfileTrustMaintenanceTests.unknownPeerRecovery` proves ordered signed refresh and unknown-peer recovery separately. `LANHandshakeTests.persistedRevocationRejectsOldCredential` proves rejection after reopening persisted evidence separately. App inbox/acknowledgement tests use injected links.

Next implement **one test-only integration fixture** connecting verified authority refresh to actual production LAN admission and durable receiver storage. Use positive controls before and after rejection. Do not expand product behavior to create this fixture. Report package integration scope honestly: app UI and full ApplicationLANRuntimeManager assembly remain separate unless explicitly included and executed.

## Fixture boundary and components

Use a unique temporary root, disposable network ID, authority key/CA, and members B (observer) and C (candidate). No existing app files or keychain identities. Bind listeners to 127.0.0.1 on allocated free ports, no Bonjour or LAN exposure. Import TLS identities into memory only, following the existing production TLS fixture. Preserve redacted result evidence before cleaning only fixture-owned files/processes.

Reuse AuthorityTrustStateCoordinator for durable signed membership/revocation publication, its real HTTPS endpoints, ProfileMembershipNetworkClient/RevocationSnapshotNetworkClient, disk-backed refresh controllers and ProfileTrustMaintenanceController. For the fixture, hold the authority coordinator in the harness and serve its endpoints through AuthorityHTTPSServer so removeAndRevoke can operate on the exact disposable ledger. The existing standalone executable exposes no removal command in its CLI; do not invent an administrative HTTP endpoint or rewrite its ledger behind a running process.

Use LANTLSConfiguration production certificate validation and NetworkBonjourConnection peer metadata, then the production membership resolver and LANTransport authentication. Use AuthenticatedTransportRouteOwner with its Boolean incoming sink and PersistentDataState: return true only after successful record, so acknowledgement follows persistence. A package-owned sink remains a bridge, not ApplicationMessageInbox. Persist snapshots through normal refresh APIs; never inject the newer revocation directly into the observer.

## Phase A — unknown membership and recovery (E2 integration)

1. Enroll/approve B and a positive-control peer; refresh B to verified generation G0. Prove authenticated control-message storage and acknowledgement. Freeze B refresh through a fixture-owned authority outage gate before C is published.
2. Approve C in the disposable authority, yielding G1. Record B still has G0 and no C. Make HTTPS authority access unavailable while retaining C's valid TLS certificate and signed credential.
3. Attempt C→B with a unique message. Require a specific membership/admission rejection; an unrelated TLS failure, missing connection or generic timeout is INCONCLUSIVE. Require no admitted route, no message record/acknowledgement and unchanged receiver file. Verify production unknown-peer recovery requests occur and repeated attempts are coalesced/throttled. Record attempt counts/timestamps against the actual backoff policy; no unbounded fixture retry loop.
4. Restore only authority access. Let the production unknown-peer recovery path fetch and verify signed revocations before membership G1. Do not manually replace B's cache or call a fake successful refresh. Retry through the production path; state explicitly if connection scheduling itself is harness-owned.
5. Require authenticated C admission, one durable copy of the original envelope, matching sender acknowledgement and empty durable pending queue. Reopen receiver storage and require exactly the expected record. Bound observation at 60 seconds; a deadline miss is a failure/inconclusive result to investigate, not a silently extended pass.

## Phase B — verified revocation and restart (E9 integration)

1. Starting from successful C admission, disconnect C's fixture connection but retain its original identity/credential. Capture its credential ID and baseline receiver bytes/count.
2. Call removeAndRevoke only for fixture C. Obtain and record authority generation G2. B learns this exclusively through HTTPS refresh controllers. Assert verified revocation is applied even if a subsequent membership refresh is unavailable.
3. Present C's unchanged old credential over a new successful production TLS connection. Use a fresh envelope/message/correlation/idempotency identity and distinct body so duplicate suppression cannot conceal unauthorized acceptance.
4. Require exact revokedCredential rejection, no admitted transport, no incoming sink invocation, no application acknowledgement and no new durable record. Compare receiver file bytes; preserve the rejected attempt's redacted identifiers.
5. Recreate B's trust directory/controllers/authenticator and store from the fixture's persisted files, with authority access unavailable. Repeat the fresh negative attempt and require persisted-evidence rejection. Label this component recreation, not an OS process restart.
6. Send from an unchanged eligible control peer to prove B still accepts authorized traffic. One accepted copy and acknowledgement are required. A test that rejects everything cannot pass.

## Result and execution rules

Record source fingerprint, OS/toolchain, test functions/cases, authority/network/node IDs, signed generations, ordered refresh events, exact rejection stage/error, request counts/timing, route/sink/ack counts and live/reopened durable records. Never record private keys, invitation secrets or credential payloads. Each phase receives its own PASS/FAIL/INCONCLUSIVE verdict; record any synthetic seam.

Before execution, build with Xcode BuildProject. Package integration may use the existing opt-in SwiftPM procedure; automated app tests remain restricted to Beakr-R1-Contract-Baseline-20261026. Do not use the shell integration wrapper that invokes xcodebuild or mutates its test plan. No automatic launch/stop of live apps. Restore the original Xcode selection if test preparation changes it.

This specification authorizes no live membership removal. Fixture C is created solely for test code, never identified by a live display name. iPhone 18 Pro remains untouched. A later hardware extension needs exact disposable device/network assignment and specifically authorized removal; successful loopback integration must not be renamed hardware acceptance.

Prepared only: no new fixture implemented or run, no build, no live listeners, no device/network/profile changes, no staging or commit. Next engineering action is to implement and validate the two-phase disposable integration fixture above.

## Execution follow-up

The isolated fixture is now implemented and its focused three-function production TLS suite passed. See the November 1 “HTTPS-refreshed production TLS negative-trust integration” entry in R1-Adverse-Conditions-Acceptance.md for outcomes and exact seams. The original NOT RUN status above describes preparation only. The private executable listener required a test-owned HTTPS wrapper; the full app runtime/hardware procedure remains unexecuted. Source fingerprints above predate this fixture.
