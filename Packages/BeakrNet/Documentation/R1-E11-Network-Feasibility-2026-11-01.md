# E11 isolated network feasibility — November 1

Status: topology proposal, NOT CONFIGURED / NOT RUN. The current inventory does not yet establish a usable impairment path. No device, router, OS, route, profile or membership changed.

## Known equipment and constraints

- Production Apple devices use 360-Starlink. Authority Mac remains Ethernet-only; do not enable its Wi-Fi or connect another LAN during this preparation.
- ThinkPad T410s reportedly uses Windows 10 (not verified) and joined 360-Rogers at 10.0.0.106, gateway 10.0.0.1; subnet mask unreported.
- Rogers gateway is ARRIS TG4482A, hardware revision 10. Earlier identification as Linksys was corrected. Do not assume this firmware exposes packet impairment controls; none have been established.
- Separate Linksys and Morse Micro equipment capabilities/current configurations remain unverified. No firmware replacement, bridge-mode change or router reset is proposed for immediate execution.
- iPhone 18 Pro and preserved XYZ archive remain excluded from all test assignments.

## Why the current connection is insufficient

Inference from the topology: a ThinkPad connected as another Wi-Fi client is not on the path between two other LAN clients. Applying impairment only to its own traffic would not exercise Beakr. Changing an Internet/WAN path similarly does not establish impairment of local Beakr traffic.

Windows Mobile Hotspot shares a connection, but its documented connection-sharing function does not establish a delay/loss facility or that Beakr local discovery will work across the proposed routing boundary. See [Microsoft Mobile Hotspot documentation](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/use-your-windows-device-as-a-mobile-hotspot). Bonjour's mDNS uses link-local multicast; a routed/NAT arrangement must not be assumed to preserve discovery. See [RFC 6762](https://www.rfc-editor.org/info/rfc6762/).

## Candidate physical path, pending hardware confirmation

```text
Spare test Mac (Wi-Fi off, test authority/peer)
      |
   Ethernet
      |
ThinkPad Ethernet port A
  Linux transparent bridge + NetEm
ThinkPad Ethernet port B (e.g. compatible USB adapter)
      |
   Ethernet
      |
Rogers gateway LAN port / 360-Rogers Wi-Fi
      |
Spare test iPhone/iPad running Beakr
```

This is a proposed isolated test arrangement, not permission to move the live XYZ Mac or physical iPhone. Use a spare Mac capable of running the required Beakr build and a spare compatible phone/tablet; if unavailable, a separately scheduled interruption or different lab approach needs a concrete plan. A simulator on the production Mac is not automatically isolated from its host networking.

A Linux bridge forwards Ethernet frames between segments ([kernel bridge documentation](https://www.kernel.org/doc/html/latest/networking/bridge.html)). NetEm can apply delay and random loss to packets leaving a selected interface ([iproute2 NetEm manual](https://manpages.ubuntu.com/manpages/noble/man8/tc-netem.8.html)). Combining them is the proposed design, subject to actual adapter/driver and multicast checks. This does not require Rogers gateway bridge mode. A temporary Linux boot is an option to assess after equipment confirmation, not an instruction to install/reboot now. Do not format media or alter the ThinkPad OS under this preparation.

Needed inventory: spare USB-to-Ethernet adapter, two Ethernet cables, spare supported Mac and phone/tablet, and willingness/means to use a temporary Linux environment on the ThinkPad. Exact OS/build/device IDs, adapter models and Linux driver availability must be confirmed before implementation. No purchases are recommended yet. Keep ThinkPad Wi-Fi from creating a bypass during an eventual bridged run; no changes now.

## Bounded run design once the path is verified

1. Establish baseline Bonjour discovery and single-copy messages both ways on disposable Beakr membership. Confirm packet/interface counters show the Beakr flow crossing both bridge ports; record IPv4/IPv6 paths and prevent alternate paths. Never infer traversal from successful Internet access.
2. Delay-only phase: propose 100 ms egress delay on each bridge port (approximately 200 ms added round trip), zero configured loss. Record exact applied parameters and measured RTT rather than treating configuration as measurement.
3. Loss-only phase: remove added delay, propose 1% random loss per direction. Record packet/drop counters and sample size; a few short messages might experience zero drops. A configured percentage alone cannot demonstrate recovery after observed packet loss.
4. Authority-access phase: restore ordinary link conditions, then block only the disposable authority HTTPS endpoint for 20 seconds and restore for 20 seconds, twice. Confirm actual endpoint/port and both IP families; leave peer data ports available. No rules are applied to the production host or router. Record whether trust requests actually occur during the outage; an idle cached-trust run alone is not intermittent-authority recovery evidence.
5. In each phase, use uniquely labelled messages, capture sender durable IDs/status and receiver one-copy receipt, and exercise Compose/navigation for visible responsiveness. After restoring conditions, apply the existing 60-second recovery observation window without Refresh, resend or app restart. Record failures instead of extending until success.
6. End by removing only fixture-owned impairment rules, demonstrating restored baseline and preserving result logs. Retain any disposable membership/history unless separately authorized for removal.

The values above are proposed starting settings, not existing results or a completed runnable command set. Exact interface names, rule handles, endpoint filters and rollback commands come after hardware/topology confirmation. No router-specific commands or unverified Windows driver tools are supplied.

## Evidence boundary and next step

Prior loopback/component tests remain valid supporting evidence, but neither this research nor a second Wi-Fi network closes E11. The full app must traverse the measured impairment path. If spare endpoints are unavailable, report that physical constraint and prepare a bounded alternative without silently relabelling another loopback test as hardware acceptance.

User input requested: available spare Ethernet adapters/cables and Apple test endpoints. No remote access to the ThinkPad is available in this session, so its current OS/adapters cannot be inspected here. The next action depends on that inventory. Documentation-only preparation; no builds/tests, installs, launches, staging or commits.


E11 tooling correction — Apple Network Link Conditioner, November 1

User correctly raised Apple's endpoint network-conditioning tools. Read-only filesystem inspection confirms /Library/PreferencePanes/Network Link Conditioner.prefPane is already installed on this Mac. Apple documents the macOS developer preference pane and iOS Developer Settings alternative (https://developer.apple.com/videos/play/wwdc2019/422/). Installation presence does not establish operational compatibility, enabled state, or that a chosen profile affects the actual Beakr LAN path. No conditioner enabled or settings changed.

The earlier conclusion that missing spare Mac/USB Ethernet hardware blocks E11 was premature. It blocks only the proposed external bridge topology. Evaluate the already installed Apple conditioner first; physical-iPhone Developer Settings may permit a narrower endpoint test without conditioning the authority Mac and its simulators together. Verify available controls and actual LAN effect before recording impairment evidence. The existing acceptance restriction against changing the production network still applies; activating impairment on a live endpoint requires an explicitly scoped test step. No purchase, Linux installation, router reconfiguration or independent-authority scope change is needed merely to investigate this option. iPhone 18 Pro remains untouched.
