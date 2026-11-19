# Network identification and connection diagnostics

Discussion saved October 28, 2026. Beakr should help people distinguish the physical network their device uses from their selected Beakr network, and understand why peers are unavailable. The motivating case was several minutes of uncertainty outdoors while reconnecting to a regularly used Starlink Wi-Fi network.

## Startup observation

In A3, with the authoritative Mac app not running, iPhone startup took about 5.48 seconds in the captured run. Sequential revocation and membership requests each timed out after approximately two seconds, accounting for about 4.02 seconds. Cached trust allowed LAN startup to complete. The 15-second peer-discovery settling interval occurred after startup and did not account for the initial red display.

Startup and indicator console reporting exposed the UI treating normal bootstrap preparation as requiring attention. After the presentation correction, the user reported blue without red on A3 startup. Authority timeouts and trust behavior were not changed to suppress the indicator.

## Network row presentation

The iPhone network header now separates the Beakr network name, a local connection detail, and concise peer connection progress. Supporting text uses standard Dynamic Type styles; subheadline was the chosen next step after footnote. Icons and disclosure chevrons should align at the top without compressing their size. Explanations belong in Connection Info, accessible from the network long-press menu, rather than wrapping in the row.

Device IP means the device's address, not the router address. Repeated private addresses across different Wi-Fi networks cannot identify Home versus Office. Comparing addresses together with subnet masks helps with subnet troubleshooting, but neither an address nor a matching Wi-Fi name proves peer reachability. Guest isolation and network segmentation can prevent communication.

The user specifically agrees that Device IP is useful for troubleshooting on Mac. A proposed iPhone refinement is to prioritize the Wi-Fi name in the row and keep the device IP in Connection Info. This refinement and any additional Mac UI work remain separate implementation tasks.

## Wi-Fi name access

The current free Personal Team could not provision Access Wi-Fi Information. The user plans to enroll in the paid Apple Developer Program as an Individual. Individual enrollment does not require an organization website. The enrollment app is named Apple Developer, published by Apple.

Beakr's opt-in code is prepared but disabled in the current build. Once membership is active, enable the iOS Access Wi-Fi Information entitlement with a supporting provisioning profile and the prepared compile condition, then rebuild. The user must enable Show Wi-Fi Name and grant location access while using the app with Precise Location enabled. The device must be connected to Wi-Fi. Membership alone does not change the installed app's capabilities.

The implementation requests the connected Wi-Fi name, not geographic coordinates. Apple's fetchCurrent API requires the entitlement and one of its qualifying access conditions; precise location authorization is Beakr's intended route. Its returned information contains SSID, BSSID, and security type, and does not populate signal strength.

Preserve existing application data and verify signing and Keychain access implications before switching provisioning. Do not delete the app or reset profiles, credentials, invitations, or messages.

## System settings access

iOS provides a supported link to Beakr's own Settings page through UIApplication.openSettingsURLString. It does not provide a supported direct link to the Wi-Fi configuration page. A proposed menu action should therefore be named Open Beakr Settings. Connection Info can explain the manual path: Settings, Wi-Fi, then the information button beside the connected network. These additions have not been implemented as part of this saved discussion.

## Proposed connection check

The user suggested something equivalent to sonar. A useful interpretation is a short, user-initiated request and reply exchange with an authenticated Beakr peer, exposed as Check Connection in Connection Info or the long-press menu. This is a proposal, not implemented behavior.

- Show progress through local connection availability, peer discovery, secure connection, and a response check, reporting only stages actually observed.
- With a connected peer, send a bounded series of small diagnostic requests and measure round-trip response times, variation, and how many replies arrive before the deadline.
- Present results such as "MacBook responds: 24 ms; 10 of 10 replies" with the target and sample time. Numbers here are illustrative.
- Call the measurement connection responsiveness or connection quality. It measures the entire path and peer processing, not radio strength or physical distance. Reliable transport may conceal packet loss through retransmission, so missed application replies must not be labeled raw packet loss.
- If there is no reachable peer, show that no peer response measurement is available. Absence of replies alone cannot distinguish weak Wi-Fi, a sleeping or closed peer app, network isolation, or different selected Beakr networks.
- Keep authority availability separate from peer availability: A3 can operate with cached trust while the authority app is unavailable.
- Use existing authenticated transport where feasible; check protocol support before implementation. Keep diagnostic traffic separate from user messages and stop promptly when the check is cancelled or the app leaves the foreground.

On macOS, CoreWLAN exposes actual local Wi-Fi RSSI and noise measurements, with availability and error handling to verify on the target Mac. These describe the Mac's own radio link; they cannot stand in for the iPhone's Wi-Fi signal. Ethernet should have no Wi-Fi signal indicator.

Recommended first increment: an on-demand peer response check with clear progress and a concise result. This would help users distinguish "connected to Wi-Fi" from "another Beakr device is reachable" without inventing signal bars.

## Follow-up after three-device A-Series testing

See [A-Series observations and follow-up](A-Series-Observations-and-Follow-Up-2026-10-28.md) for the observed test outcomes, prioritized investigations, and recommended next steps.

Additional discussion saved October 28, 2026. Defer implementation until the current A-Series tests with the Mac, physical iPhone, and iPhone simulator are completed and findings recorded. The user wants optional connection-quality monitoring with rolling history per peer and a visual heatbar or heatline. This is an investigation milestone, not an implemented feature or a change to current connected-state rules.

### Measurements and rolling history

Track the following as distinct measurements, with timestamps, source, and availability:

| Measurement | Meaning and limits |
| --- | --- |
| Link rate | Negotiated local interface rate where a supported OS API exposes it. Show unavailable otherwise. It is not end-to-end speed or radio signal strength. |
| Available path capacity estimate | Estimate from a bounded transfer test between peers. A short burst cannot establish theoretical capacity; congestion, transport behavior, and endpoint processing affect the result. |
| Actual throughput | Delivered application bytes over measured time during real transfers or explicit tests. Idle time must not count as zero transfer performance. |
| Responsiveness | Request/reply round-trip times, variation, missed reply deadlines, and time since the last confirmed reply. TCP retransmissions conceal raw packet loss. |

Compare current measurements with a recent baseline for that peer and network context. Reset or separate baselines when the network or connection changes; account for foreground/background transitions and insufficient samples. Show a learning state until enough observations exist. Decide sampling intervals, history retention, thresholds, and traffic budgets during investigation rather than treating illustrative numbers from the discussion as requirements.

Small heartbeats can measure responsiveness while the app is active. Larger, optional bursts can estimate transfer performance in each direction. The receiving app must confirm receipt of the complete test payload: local send completion or flushing buffered writes does not establish remote application receipt. Use deadlines and bounded tests; avoid saturating the network during normal use.

### Controls and presentation

- Provide a user setting to turn monitoring on or off; separately control heavier, on-demand connection tests.
- Investigate a per-peer heatbar or heatline, with accessible text describing the result and access to numeric measurements, sample age, and recent history.
- Possible descriptions include Responsive, Slow responses, Intermittent, Not responding, and Learning connection quality. These are proposals, not finalized thresholds or UI text.
- Keep authenticated connection state distinct from measured responsiveness. A locally registered connection can persist through silent network failure until transport errors or communication deadlines expose it. A missed reply alone should not immediately imply revoked membership or permanent disconnection.
- The recurring Connectivity peer-update console entry reads locally held authenticated peer state; it is not itself a network ping. Existing periodic device-IP reports are not a timed request/reply health check.

### Location and distance

Precise Location may support eligible Wi-Fi-name access, helping label histories by physical network context, but does not unlock throughput or path-capacity measurements. A Wi-Fi name alone does not uniquely identify a network segment.

Exchanging geographic coordinates could estimate separation only within the accuracy of each device's location. Indoors, uncertainty can exceed the separation; Mac and simulator locations may not be independent useful observations. Peer-to-peer distance also does not establish distance to an access point, wall attenuation, or interference. Do not require geographic location for connection-quality monitoring or represent these tests as distance or Wi-Fi signal measurements.

### Related A-Series findings to retain

- After admitting a third device, the Mac showed three devices online while each iPhone initially showed two. Backgrounding and foregrounding the physical iPhone corrected its view. Subsequent observation showed the physical and simulated iPhones discovering each other successfully. Investigate refresh/reconnection while continuously foregrounded; a 15-minute scheduled membership refresh is a possible contributor, not a proven complete cause.
- The Mac showed three separately identified pending join requests for an already connected iPhone, still offering Allow and Don't Allow. Determine whether these are persisted pending requests or stale UI, and how later successful enrollment should reconcile earlier requests. Preserve registration/audit history; do not delete invitations, requests, credentials, or other application data as a diagnostic shortcut.

Suggested investigation order: finish A-Series reproduction notes; resolve membership/request freshness defects; prototype peer response measurements and bounded transfer tests; evaluate rolling baselines and visual presentation before changing connected-state decisions.

## Apple references

- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/)
- [Enrolling using the Apple Developer app](https://developer.apple.com/help/account/membership/enrolling-in-the-app)
- [Current Wi-Fi information and access requirements](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:))
- [Opening an app's Settings page](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring)
- [Apple DTS guidance on opening Wi-Fi Settings](https://developer.apple.com/forums/thread/65007)
- [CoreWLAN signal strength](https://developer.apple.com/documentation/corewlan/cwinterface/rssivalue())
- [CoreWLAN noise measurement](https://developer.apple.com/documentation/corewlan/cwinterface/noisemeasurement())
