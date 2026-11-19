# Independent authority hosting — behavior specification, November 3, 2026

Status: proposed implementation contract following the R1 evidence reconciliation. No product implementation, migration, acceptance pass or live-device change is implied. This phase defines behavior; implementation follows separately.

User clarification: this is experimental software; backward compatibility with older builds is not required. All participating devices may be required to run the updated build. No legacy protocol, fixed-port fallback or mixed-version support is an acceptance requirement. Existing identities, memberships and history must still be preserved; iPhone 18 Pro remains untouched and outside the rollout.

## Purpose and scope

A Mac hosting XYZ must continue serving XYZ enrollment, membership and revocation requests when its messaging participation switches to another network. Displaying a network's settings must not change either service. Hosting permission, hosting availability, messaging participation and UI selection are separate states.

For this increment, retain one active messaging network per app. Several locally owned authorities may run concurrently. Hosting an authority does not make the Mac an online messaging peer in that network. This increment does not add relay, cross-network forwarding, concurrent messaging, a background daemon or iOS authority creation. Quitting Beakr stops its in-process authorities; merely closing a window must follow the application's existing process lifetime. No promise of service while the Mac sleeps.

The [node design principles](Node-Identity-Routing-and-Relay-Principles-2026-10-30.md) establish the separation goal; their broader multi-network and mesh proposals are not all R1 commitments. The [multi-network planning document](BeakrNet-Multi-Network-Planning-and-Discussion.md) already proposes dynamic authority endpoints and Bonjour discovery. Its older implementation descriptions must not be treated as current source.

## Source findings

- Apps/Beakr/NodeBootstrapModel.swift holds one localAuthority. start restores the selected profile's authority; switchNetwork explicitly stops it before starting the next profile.
- Invitation creation, pending requests, approval/rejection, export/verification, removal and rename use that same selected authority reference. They need explicit network context before multiple authorities can be supported safely.
- Additional-network creation persists a prepared authority without binding a listener; first-network creation activates and restores it. Keep existing creation continuity and rollback behavior.
- Apps/Beakr/AuthoritativeNetworkCreator.swift scopes identities/secrets/bundles per profile. restore obtains hostname/port from the saved manifest and starts EmbeddedAuthorityNode at that endpoint.
- NodeBootstrapModel defaults authorityPort to 8443. Concurrent listeners cannot assume all historical profiles have distinct usable endpoints. Actual saved-profile endpoint inventory has not been collected in this phase.
- Existing trust/enrollment clients receive a controlPlaneURL. Changing only the host's port is not a complete recovery or migration mechanism.

## Proposed user-visible contract

| Action | Authority hosting | Messaging and selection |
| --- | --- | --- |
| Inspect another network in Settings | No start/stop caused by inspection. Show that network's hosting state. | No participation switch. |
| Make another network Active | Existing enabled authorities continue running. Start the new network's enabled local authority if needed. | Existing single-network switch and queue/history isolation remain. |
| Start Hosting for an owned network | Enable and start only that authority; persist intent. Report success only after listening. | No participation switch. |
| Stop Hosting | Disable and stop only that authority; persist intent. Explain that authority-dependent operations become unavailable. Memberships and credentials are retained. | Existing cached-trust peer messaging follows current rules; no forced membership removal. |
| Create an additional network | Preserve existing creation behavior: prepare the new authority, initially hosting disabled until an explicit hosting/activation action. | Existing network keeps running; new messaging profile stays inactive. |
| Create the first network | Enable hosting and activate messaging through the existing creation transaction. | First-network automatic activation remains. |
| Restart Beakr | Restore explicitly enabled authorities independently; one failure does not stop the rest. | Restore the saved active messaging profile independently. |
| One authority fails | Show its error and bounded recovery state; retain intended hosting state and keys. | Do not mark unrelated networks failed or restart their messaging. |

Proposed labels: Authority Hosting: Starting, Running, Stopped, Unavailable (with actionable error). Keep ownership/administrative capability separate from Running. Keep current network blue/green connectivity meaning based on authenticated messaging peers; authority availability alone must not turn it green or increase Devices Online.

A stopped owned authority may still support offline operations only where the existing security/persistence contract explicitly allows them. Do not imply that a generated invitation proves the service is reachable or that enrollment has completed.

## Ownership and concurrency

Introduce an application-owned authority host manager, keyed by stable profile/network binding, with one owned lifecycle entry per authority. It owns running instances, start/stop tasks, errors, endpoint advertisements and cleanup. Messaging-runtime stop/reconnect/profile-switch paths do not own these services.

Serialize operations per authority and coalesce duplicate starts. Use lifecycle generations or equivalent cancellation checks so a delayed start cannot resurrect a stopped service. Stop must cancel pending recovery and close the listener and issuer temporary resources before its completion is reported. Bound recovery attempts with backoff; an unavailable authority must not cause an app-wide restart or retry storm.

Administrative requests must carry the intended profile/network identity from initiation through completion. Switching the selected screen while approval is pending must never redirect that request to another authority. Reject missing/mismatched ownership rather than falling back to whichever authority is selected. Keep ledgers, audit exports, keys and invitation state separate.

Persist intended hosting separately from actual availability and active messaging selection. A crash or unavailable Keychain must not erase that intent, grant ownership or generate replacement credentials. Explicit stop persists disabled intent before another restore can race it.

## Authority endpoint discovery

Use distinct bound endpoints for concurrent authorities, including authorities for existing profiles. Bind an available port and publish the actual endpoint; handle bind failures explicitly. Do not publish a guessed free port as a working endpoint. No requirement to retain port 8443 or support older fixed-endpoint clients.

Updated hosts and clients use one authenticated endpoint-resolution design:

1. Treat Bonjour records as untrusted candidate routes scoped to the expected NetworkID, not authority proof.
2. Preserve the installed authority identity and existing TLS/CA validation. Candidate selection must not disable hostname validation or allow arbitrary network/key substitution.
3. Verify the expected network/authority binding before trusting a newly discovered endpoint; keep signed membership/revocation verification and freshness checks unchanged.
4. Define bounded discovery, signed endpoint metadata or an equivalently authenticated binding, stale-record rejection and failure reporting. Any endpoint cache is a performance aid, not a legacy compatibility mechanism or source of trust.
5. Updated clients must demonstrate recovery after port reassignment without re-enrollment. Mixed-version operation is unsupported and need not be tested.

Implement the host and client changes together. Port allocation must not evict another working listener. Concurrent hosting acceptance requires multiple authorities to bind successfully and updated clients to locate the correct authority without losing identity or trust isolation.

No live endpoint changes occur during this design phase. The implementation may update stored endpoint metadata when the new build is deployed, preserving NetworkIDs, node identities, authority keys, memberships, queues and history. Record participating updated builds; no live identity, membership or history deletion is needed.

## Proposed initial hosting policy

Do not enable every saved historical/test authority automatically. On first migration, record enabled intent for the currently active locally owned authority, preserving current startup behavior. Other existing authorities remain disabled until explicitly enabled. On later launches, honor saved intent even if another messaging network is active.

After this initial state is recorded, Start Hosting and Stop Hosting control hosting independently. Make Active changes messaging participation and does not enable a disabled authority. First-network creation still enables hosting as specified above. This is a proposed policy to implement and validate, not an already-observed app behavior.

## Implementation sequence and acceptance

1. Establish persisted hosting intent, authority-manager ownership and deterministic lifecycle tests with injected authorities; separate messaging switch/shutdown from application shutdown.
2. Route administration by immutable profile/network context and expose independent hosting status/actions. Review all existing localAuthority call sites, including reset/removal/error cleanup; no test execution of destructive live actions.
3. Implement and validate dynamic endpoint resolution in hosts and clients together. Preserve TLS and signed-trust policy; do not solve routing by weakening authentication. Do not add backward-compatibility branches.
4. Integrate startup, creation and failure rollback; validate the scoped cases below before preparing a controlled deployment.

| Required check | Evidence needed |
| --- | --- |
| Switch active messaging A to B | A's authority remains reachable with the same identity; its host instance is not stopped/recreated by the switch. Messaging still switches and isolates queues. |
| Administer A while viewing/participating in B | A receives the operation; B's ledger/keys/state remain unchanged, including delayed completion after UI selection changes. |
| Duplicate start / stop during start / rapid changes | At most one listener per authority; no stale completion restarts a disabled service; owned tasks/resources settle. |
| One authority unavailable or port occupied | Other authorities and active messaging remain functional; clear per-authority failure, bounded retries and no credential replacement. |
| App relaunch | Saved hosting intentions restore independently of messaging selection; explicitly stopped authorities stay stopped. |
| Dynamic endpoint resolution | Updated clients recover after port changes with the original trust identity; spoofed/wrong-network/stale candidates are rejected. No old-build compatibility test. |
| Creation and rollback | First creation activates; additional creation preserves current network; failed creation affects only its new setup. Existing E13 passes remain prior evidence, not validation of changed lifecycle code. |
| Independent service and UI status | Hosting Running with inactive messaging does not imply green peer connectivity; stopping hosting does not delete membership or queue state. |

Package/component tests may use disposable fixtures. Automated app interactions remain restricted to Beakr-R1-Contract-Baseline-20261026 (E40CDB24-C697-4F57-8F87-CBFD9DFADDD5); that iOS simulator cannot prove Mac embedded-authority behavior. Mac app builds use Xcode BuildProject, with eventual user-driven Mac checks. No spare Mac/test account exists, so clean-install Mac UI acceptance remains unavailable unless an explicitly agreed isolation method is prepared later.

## Phase outcome

Behavior and implementation boundaries are documented; code and devices are unchanged. Open implementation design work is authenticated dynamic endpoint discovery, followed by lifecycle integration. Backward compatibility is explicitly out of scope by user direction. Do not label the authority feature implemented, deployed or accepted from this specification. Preserve all workspace/staging changes, XYZ identities and test histories; never touch archived iPhone 18 Pro.


## Follow-up: UnObserved and multi-network presence — November 6, 2026

User selected the provisional category spelling **UnObserved**. Its scope is this observing node, this Beakr'Net network, and this software version's capabilities. It makes no claim that a member is offline, deliberately hidden, or unavailable on another network. Another observer on the same network may have different evidence. Suggested explanatory text: “This device isn’t currently observing presence on this network.”

The existing product supports multiple saved networks and independent Mac authority hosting; messaging/presence observation currently follows one selected network. Future scope should include authenticated presence observation across multiple Beakr'Net networks independently of the network currently viewed or selected for messaging. A member's online state in one network must never establish presence or permissions in another.

This is a design follow-up, not implementation or acceptance of concurrent multi-network runtimes. Before that work, specify per-network observer lifecycle, authorization, freshness/expiry, resource limits, iOS background behavior, and isolation of identities, messages and delayed callbacks. Messaging service activation, UI selection, authority hosting, and presence observation need distinct state. Existing R1 signoff and E14/E15 acceptance remain separately tracked; this terminology change does not broaden their acceptance claims.


## Status reconciliation — November 7, 2026

The source findings, proposed policy and Phase outcome above describe the original November 3 design phase, not current implementation status. Independent per-network Mac authority hosting and authenticated dynamic endpoint discovery are now implemented. The acceptance record reports automatic port-change recovery without manual refresh or baseline restart on November 5: port 49967/generation 6 to port 49968/generation 7, historical baseline PID 13694/session 77a14f9980, zero failed consumers and unchanged membership. Earlier manual-refresh recovery remains separate evidence. These scoped passes do not certify every row of this specification's acceptance table or full R1.

November 6 Mac/physical-iPhone saved-member and per-network identity display checks, including the 23:42 local-IP/notice correction PASS, are reconciled in [R1 acceptance](R1-Adverse-Conditions-Acceptance.md). E15 switch/return isolation and full E14 live acceptance remain open. UnObserved is observer- and network-scoped; the local device's known IP does not establish inactive-network presence, and expired saved information cannot authorize live communication.

Multiple simultaneous messaging/presence networks and Host/Co-Host service roles remain future design work, not implemented features or automatically part of R1. Existing independent authority hosting must not be confused with those future service roles. No new UI/runtime design or live test is introduced by this reconciliation.


### Mac messaging switch preserves XYZ authority service — scoped PASS, November 7, 2026

After Mac messaging switched XYZ → R1-E8-Test, user reports the requested physical-iPhone XYZ Refresh completed with no errors and XYZ members remained visible. Desktop screenshot at 20:37 shows Mac E8 selected for messaging, blue with one device online; XYZ inactive for Mac messaging with five saved members UnObserved, and both XYZ/E8 green authority icons. Screenshot alone does not show the physical phone; its refresh result is user-reported. Historical saved names in inactive XYZ are not evidence of current presence.

Verified macOS console session 7c6c5e5800 / PID 82741 records XYZ credential-revocations at 20:34:43.581 and profile-membership at 20:34:43.612, after the Mac profile switch at 20:32:37. TLS server activity on local port 49986 with a remote en0 link-local address accompanies these operations. Read-only lsof still shows XYZ's original listener port 49986 / FD 4u / socket identifier 0x72d54417cbe25a17 in the same process. E8-associated port 49990 also remains unchanged. Together with the user-reported successful client refresh, this supports scoped PASS for XYZ authority listener/service continuity while the hosting Mac uses E8 messaging. No client-side signed generation or response payload was independently captured; no claim of every request succeeding or exhaustive zero-duration interruption detection. The deliberate Refresh is a service probe, not automatic recovery evidence.

Return/cleanup remains pending: user to restore Mac Use Messaging to XYZ, confirm green and existing XYZ identity/history, then stop temporary E8 hosting while retaining XYZ hosting. Full R1 remains open. No agent app interaction, source change, build, staging or commit.


### Mac authority-continuity cleanup complete — November 7, 2026

User confirmed E8 hosting Stopped, XYZ hosting Running, and XYZ selected/green on Mac and physical iPhone. Read-only verification in running macOS session 7c6c5e5800 / PID 82741 shows XYZ's original listener unchanged at port 49986 / FD 4u / socket identifier 0x72d54417cbe25a17; E8-associated port 49990 is absent. Messaging listener remains port 49992. This completes the bounded Mac XYZ → E8 → XYZ messaging-switch / independent XYZ authority-service continuity phase, including restored hosting intent and user-confirmed original Mac identity/history. Scoped PASS; no exhaustive interruption timing or client signed-generation capture claimed. E14/E15 remain complete within their accepted scopes; full R1 remains open.

Next single phase: E1/E3 evidence-limit disposition. Existing cold-start/outage/recovery observations and controlled regressions are established; complete live trust-freshness-boundary soak and correlated signed-refresh/retry trace are not. Recommend explicit acceptance of existing scoped evidence with those limits retained, not recording unperformed variants as passes. No further live action requested during that decision. Remaining E2/E6/E11/E9/E13 and hosting edge-case dispositions and final build/install inventory remain outstanding separately. No source/build/app changes, staging or commit.


### Independent-hosting disposition accepted; final Mac build — November 7, 2026

User explicitly answered “yes” to accepting independent hosting within its recorded live/component evidence scope, retaining delayed-administration completion after UI selection changes and occupied-port/startup-failure UI scenarios as lacking full live UI verification. Hosting acceptance is COMPLETE within that agreed scope; this does not turn unperformed variants into passes. Full R1 remains open for final source/build/install validation.

Final inventory preparation compared all 269 source/config manifest entries and current eligible Git-listed paths: no changed, added or removed entries relative to /tmp/Beakr-R1-source-inventory-20261107.json (SHA-256 d81649d55370f6b7e5b0ed5e45ea8819a40e1dab7ea09f0fe1d58c98c9c53d61). Existing manifest scope excludes documentation/assets and is not a complete build-input fingerprint. No source edits since the 19:58 isolated inactive-name regression; no repeat of that passed test warranted.

Xcode verified Beakr / My Mac active. BuildProject passed at 20:48 with no reported errors; BuildProject-Log-20261107-204819.txt in ActionArtifacts/FDF24040-C162-41A6-998B-799DE54A413E/BuildProject. Build reason: final Mac compilation of the later shared Friendly Name preference-injection change, previously only built/tested for baseline. No Mac launch/stop or other automated app interaction performed. Built executable SHA-256 bd7236ec402265942e575062e63515219926e26598a68769175c3cfd77d0b8a2; Beakr.debug.dylib SHA-256 7d5d9312952ea2270a7da324cde8031dea2cffd36d2e996c05c45ad8c44f9f1c. Paths recorded in /tmp/Beakr-R1-Mac-build-inventory-20261107.json. These identify on-disk build outputs, not the still-running older process or every app-bundle resource.

Next single phase: user confirms Conditioner still OFF and runs this final Mac build via Xcode My Mac, then confirms original Mac name/XYZ Node ID suffix A98/history, XYZ messaging green, XYZ hosting Running and E8 hosting Stopped. This is a bounded final-build preservation/startup check, not a repeat of full E14 or the authority-switch exercise. Physical-iPhone/original-simulator final build/install inventory remains subsequent work. No stage/reset/commit; existing workspace preserved.


### R1 FINAL ACCEPTANCE — user-approved November 7, 2026

User explicitly answered “yes” to “Do you accept R1 complete within that documented scope?” R1 is COMPLETE AND ACCEPTED within the documented scope and individually approved evidence limitations. This final acceptance supersedes earlier open/ready/pending-signoff statements; those dated records remain historical. No unperformed variant is reclassified as a test PASS, and no broader product scope is implied.

Basis: recorded E1–E15 scoped evidence and explicit dispositions; independent per-network authority hosting/dynamic endpoint recovery and Mac messaging-switch continuity; completed final Mac, physical iPhone-Dev and original iPhone 17 (iOS 27.0) Xcode builds, loaded-build verification and user-confirmed name/node/history/green startup checks. The unchanged-source baseline regression remains PASS 1/1; no new full-suite or final-build roundtrip claim. Source/config manifest and executable/library fingerprints are recorded in the final inventory, with their exclusions retained.

Final confirmed state: Mac and physical iPhone use XYZ; original iPhone 17 also XYZ green. Original names/identities/history retained. Mac XYZ authority Running, R1-E8-Test authority Stopped. Conditioner last reconfirmed OFF. Xcode destination remains iPhone 17 (27.0). No further R1 action pending under this acceptance; no new phase started.

Separate follow-ups remain outside accepted R1: authority hosting-state icon/visibility request; Device Hub Command-A/Command-V shortcuts; future simultaneous multi-network messaging/presence and Host/Co-Host service-role design. Protected iPhone 18 Pro and all preserved memberships/profiles/history remain untouched. This acceptance does not authorize staging, commits, deployment/publication or broader feature work. Documentation-only recording; workspace/index changes preserved, no reset/stage/commit.
