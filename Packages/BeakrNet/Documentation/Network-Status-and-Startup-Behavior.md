# Network Status and Startup Behavior

Beakr displays one active network and any additional saved network profiles. The active network's icon represents secure LAN readiness and peer connectivity; inactive profiles remain grey.

## Icon colours

- **Grey:** The profile is inactive, or the active profile has no usable local network.
- **Orange:** The active profile is starting or reconnecting. The user ordinarily cannot resolve this state directly.
- **Blue:** The secure LAN runtime is ready but no authenticated peers are online. Both “discovering devices” and “ready, no devices online” are blue.
- **Green:** One or more authenticated peers are connected.
- **Red:** Startup or connection failed and user intervention may be required.

## Active network selection

Creating or joining a network activates the new profile, so the most recently created or joined network normally becomes active. Beakr persists the active selection. If the user later switches networks, that manually selected network remains active after restarting, regardless of creation order.

## Startup timing

The code contains two explicit presentation or lifecycle delays:

- A 300 millisecond delay before reconnecting when the application returns to the foreground.
- A 15 second discovery interval before changing the status from “Discovering devices” to “Ready, no devices online.” Both states are blue, so this interval should not delay the icon becoming blue.

The orange-to-blue transition waits for secure startup work: authority restoration, Keychain identity loading, certificate and revocation recovery, membership restoration, Bonjour runtime startup, and local-network availability detection.

Explicit reconnection has an eight-second startup deadline. Initial application startup currently invokes LAN startup directly and does not use that same deadline. A slow secure-startup operation can therefore leave the initial state orange longer than intended.

## Recommended follow-up

Initial startup should use the same bounded runtime-start path as reconnection. Timing diagnostics should separately measure authority restoration, trust recovery, membership loading, Bonjour startup, and local-network availability detection.

## Testing observation

On October 12, 2026, the iPhone network icon was observed in the red failure state. After moving Beakr to the background and returning it to the foreground, the icon became grey. Investigation is continuing. This transition suggests that foreground reconnection cleared the failure state but did not detect a usable local network; logs should be checked before assigning a root cause.

The expected foreground sequence is pulsing grey while reconnecting, pulsing blue while discovering, and then solid blue without peers or green with authenticated peers. The implementation was found to skip foreground recovery unless bootstrap state was already `ready`. A failed initial LAN start can leave valid runtime and authority configuration in `identityReady`; backgrounding then changes connectivity to inactive, and foregrounding skips recovery, producing the observed solid-grey icon. Foreground recovery should instead retry whenever a valid active runtime and configuration remain available.

## Peer connection initiation

The authority-hosting Mac is not special in peer connection establishment. Every active Beakr peer runs both a Bonjour browser and listener. To prevent two simultaneous connections, the peer with the lexicographically lower Node ID initiates and the other peer accepts. Either the Mac or iPhone can therefore initiate for a particular pair. Authority hosting controls network administration and enrollment; it does not assign the Mac a permanent connection-initiator role.

Bonjour advertisements signal availability; they do not assign the receiving device the initiator role. A blue Mac and grey iPhone indicates that the iPhone's active LAN runtime is unavailable, or that the devices have selected different active networks. Once both devices have the same active Network ID and usable runtimes, one side should deterministically initiate.

## Foreground recovery correction

Foreground recovery now retries whenever an active runtime and authority configuration remain available, including after an initial LAN failure left bootstrap in `identityReady`. The regression test covers red failure, background transition to inactive, and successful foreground reconnection. The macOS build succeeds and all 24 application unit tests pass after this correction.

## Different active networks

A device can retain profiles and Contexts for several networks, but only one network currently owns the active LAN runtime. Two nearby devices that share a saved network will not connect if each has selected a different active network. Their inactive saved profiles remain grey and do not browse, advertise, accept connections, or initiate connections.

This raises a product decision for future work: whether Beakr should remain strictly single-active-network, clearly identify a nearby shared but inactive network and offer an explicit switch, or eventually support more than one concurrent active runtime. Automatically switching networks merely because a peer is nearby would be surprising and could conflict with routing and data-movement rules; an explicit suggestion is the safer near-term design.

## Current testing scope

Until multi-network behavior is designed and implemented, connection, discovery, foreground recovery, icon-state, and message-delivery testing will be limited to a single network on the Mac and iPhone. This isolates LAN and lifecycle behavior from active-network selection differences.

## iPhone mailbox hierarchy

The first page uses `Beakr'Net` as its page title, followed by a `Networks` content heading separated by 10 points. Networks are the organizing concept because Mailboxes, future Data Stores, and Rules are indexed to them. Each network name then labels the Inbox and Outbox belonging to that network. The active network name uses the toolbar network icon's connectivity colour, while inactive saved network names remain grey. Inbox and Outbox labels retain their normal colour because stored mailbox availability is independent of current connectivity.

This hierarchy separates application, content type, network ownership, and virtual mailbox folders. Preserved Contexts remain unchanged until their final placement and presentation are decided. Accessibility exposes the network's textual status so colour is not the only distinction.
