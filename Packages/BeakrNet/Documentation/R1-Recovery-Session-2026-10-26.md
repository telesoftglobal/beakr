# Beakr R1 recovery discussion — October 26, 2026

This is a saved summary of the discussion and responses, not a verbatim console transcript. Detailed code mapping, validation evidence, and investigation history are in R1-Message-Submission-Control-Point.md and its printable PDF.

## Observations and interpretation

Hamilton was selected on both devices with Network ID 267EDEF2-F6A4-4D60-B886-DEB839A737F7. Rejoining via invitation was rejected because the network already existed locally. Selection, membership, runtime state, and connectivity are distinct; rejoining was not the required repair.

Early runs varied with timing: restarting either app could reconnect automatically or leave Mac blue and iPhone grey/red. Manual Refresh on either side, or restarting the iPhone, restored connectivity in different runs. Two seconds of blue before green was not itself a failure; remaining disconnected for minutes was.

The screenshots showed Hamilton Active but This Device Offline. The main screen showed a green local-device dot while the detail view showed offline. That presentation inconsistency remains a separate follow-up; this repair does not claim to fix it.

## Diagnostics and confirmed cause

The diagnostic build emits console records with wall-clock epoch timestamps, uptime, profile IDs, runtime generations, and reconnect/start identifiers. The records are operational diagnostics, not an Actor audit journal. Console output belongs to the app launched by Xcode; Mac and iPhone sessions are separate. Clear the console only before a reproduction, preserve failure output, then capture the successful manual recovery.

Mac logs showed successful startup and an unchanged runtime accepting the restarted iPhone. nodeIDHintCollision means an advertisement contains the local Node ID and can simply be self-discovery; it did not establish duplicate identities. SSL cached-certificate warnings also occurred on successful connections and did not establish the failure cause.

The iPhone trace supplied the decisive sequence:

| Event | Epoch timestamp | Meaning |
| --- | --- | --- |
| Connection closes | 1793068292.534 | Mac peer is lost. |
| Automatic full restart | 1793068292.570 | iPhone stops its own listener/browser. |
| Trust refresh begins | 1793068292.575 | Authority is unavailable while Mac is shut down. |
| Startup timeout | 1793068300.603 | Eight-second deadline cancels startup; connectivity becomes failed/red. |
| Periodic peer update | 1793068301.727 | Cleared local-availability flag causes failed to be overwritten by inactive/grey. |

No further recovery attempt occurred in the supplied trace. Timing affected whether the authority was available during the unnecessary restart; a separate unproven race is not needed to explain this sequence.

## Repair and verification

The app no longer performs a full runtime restart when its last peer disappears. Existing Bonjour connection retry/discovery remains responsible for peer return. Trust maintenance and membership/authentication checks remain intact. Periodic peer updates preserve reconnecting/failed states, and Last Error reflects connectivity failure even when bootstrap state remains ready.

Two new app regressions reproduced the defects before repair. Afterward, all 47 app tests passed. Three supporting discovery tests were changed to wait for observable asynchronous events rather than assume a fixed number of yields was sufficient; all 13 focused discovery/membership tests passed. No physical profiles, Context data, messages, or credentials were deleted or replaced.

The user then reported: both return to green after restart; when one is shut down, the other remains blue indefinitely. The response confirmed that this is expected: blue means ready with no connected peer, and green returns after authentication. This restart scenario is now marked passing, with overall R1 acceptance still separate.

## Remaining work

Continue bounded R1 acceptance and review the local-device indicator discrepancy. Retain diagnostics for recurrence. Do not claim a new complete package run or a fix for every startup failure. Keep Hamilton/Queens test data and all existing staged, unstaged, and untracked changes. No Release 2, new Actor permission schema, or general Node runtime was introduced.

### Connectivity terminology recorded during October 27 hands-on testing

The current connectivity enum uses `inactive -> reconnecting` during an ordinary cold start. The observed behavior is healthy, but the terminology combines distinct lifecycle concepts and makes console interpretation harder:

- `starting` is the application/runtime lifecycle operation before a usable LAN runtime exists;
- `connecting` is the first attempt to establish discovery and authenticated peer routes for that runtime;
- `reconnecting` is recovery after a previously usable runtime or route was interrupted;
- `refreshing` is trust/membership reconciliation triggered by startup, maintenance, or an explicit user action and should be logged as an operation rather than treated as a connectivity state;
- `inactive` should describe a settled nonoperational state, such as a profile that is not selected or a runtime that has intentionally stopped, rather than the initial moment of application startup.

A clearer cold-start trace would be `starting -> connecting -> discoveringPeers -> connected` (or a ready-with-no-peers outcome). Recovery would use `reconnecting`. This is recorded as a bounded R1 state/terminology follow-up, not authorization for the broader post-R1 connectivity architecture rewrite. Before implementation, map the terms to bootstrap state, runtime ownership, UI colours, accessibility text, and existing tests so no behavior or trust rule changes accidentally accompany the naming refinement.

Active-profile switching needs the same precision. The October 27 Hamilton-to-Queens trace correctly stopped Hamilton and notified its authenticated iPhone peer, but exposed only the generic lifecycle reason `runtimeStopping` and reset bootstrap from `ready -> starting`. A bounded R1 refinement should carry `profileSwitch` as the stop/lifecycle reason when an active-network selection causes the runtime stop, while retaining `runtimeStopping` for an otherwise unclassified internal stop. The bootstrap trace should also identify that this is startup of the newly selected profile rather than implying a cold application launch. This is a terminology and diagnostic change only: it must not change trust validation, profile identity, graceful peer notification, or runtime ownership.

The user paused for the day and requested a printable Message Submission Control Point PDF, saved discussion, and startup text for the next conversation. These artifacts accompany this note.
