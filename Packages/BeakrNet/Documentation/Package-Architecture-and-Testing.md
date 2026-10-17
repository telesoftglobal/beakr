# Package Architecture and Testing

This document defines the module boundary for the application-channel milestones that follow the completed BeakrNet transport and certificate-lifecycle foundation.

## Architectural rule

Application features may depend on networking, but networking must not depend on application features.

The dependency direction is:

```text
Beakr application and UI
        ↓
Application services and repositories
        ↓
Data and Blackboard protocols
        ↓
BeakrNetControl
        ↓
BeakrNetCore
```

Security, authority, and transport targets depend on `BeakrNetCore`; they must not depend on application Data or Blackboard modules. Relays continue treating application payloads as opaque.

`BeakrNetOperations` is a platform-neutral deployment-policy boundary depending only on `BeakrNetCore`. It owns validated production profiles, admission policy, safe audit/telemetry schemas, backup verification, restore activation gates, and deterministic recovery drills. Concrete KMS, HTTP server, monitoring, and orchestration adapters remain outside the package and may not weaken protocol verification.

## Milestone 6 target

Milestone 6 is named **Typed Control Protocol**. It is the first milestone in the broader **Application Channel Semantics** phase.

Implement it as a new platform-neutral library target and product inside the existing BeakrNet Swift package:

```text
BeakrNet
├── BeakrNetCore
├── BeakrNetControl
├── BeakrNetSecurity
├── BeakrNetAuthority
├── BeakrNetRelayTransport
└── BeakrNetTestSupport
```

`BeakrNetControl` depends on `BeakrNetCore`. It must not import SwiftUI, Network, Security, or an application target. It owns typed Control payload schemas, canonical encoding and decoding, semantic validation, and protocol dispatch. `BeakrNetCore` continues owning envelopes, channel identity, sessions, delivery bookkeeping, and transport-neutral primitives.

`BeakrNetData` depends on `BeakrNetControl` and `BeakrNetCore`. It owns reusable Data message semantics and durable node-side protocol state, while application repositories own product mutations and schemas. It likewise remains independent of SwiftUI, Network, Security, and application targets.

Do not place product networking implementation in an Xcode application project. The dedicated `BeakrNetIntegrationHost` project provides only the signed process required for a small number of end-to-end Apple-platform checks; all reusable behavior remains in the `BeakrNet` package.

## Change boundaries

The new target protects the stable networking foundation from application-protocol churn:

| Change | Expected scope | Regression risk |
| --- | --- | --- |
| Add a typed Control payload | `BeakrNetControl` | Low |
| Change Control dispatch or authorization | `BeakrNetControl` and its consumers | Moderate |
| Change the envelope wire contract | `BeakrNetCore`, persistence, every transport | High |
| Change acknowledgement or retry behavior | Core sessions, relay/LAN handoff | High |
| Add an application Data operation | Data/application module | Low to networking |
| Change Blackboard merge policy | Blackboard module and repositories | High within Blackboard, low to networking |
| Change SwiftUI behavior | Application targets | Low to networking |
| Change Network.framework, TLS, or Keychain behavior | Platform adapters and signed hosts | Platform-specific |

Changes to `BeakrNetCore` during application milestones require an explicit justification. A convenience requested by an application protocol is not, by itself, a reason to weaken envelope validation, authentication, revocation freshness, resource bounds, or route eligibility.

## Application Data module

Milestone 7 introduces a generic `BeakrNetData` target because its message, request/response, cancellation, correlation, and idempotency contracts are reusable and independent of product schemas. `BeakrNetData` depends on `BeakrNetControl` and `BeakrNetCore`. Product-specific operations and application handlers belong above that target.

## Later module decisions

Milestone 8 Blackboard work should begin behind a separate module or Swift package boundary. Repository implementations, schema migration, causal synchronization, compaction, and conflict policy will evolve at a different rate from networking. The design gate must decide whether the reusable portion belongs in this repository as `BeakrBlackboard` or in a separate Swift package before implementation begins.

The production Beakr application owns product schemas, application services, lifecycle coordination, and SwiftUI. `BeakrNetDemo` remains a protocol and networking laboratory rather than becoming the production application.

## Test layers

### Pure package tests

Add `BeakrNetControlTests` beside the new target. These tests run with the ordinary package suite and cover:

- Canonical encoding and golden fixtures.
- Every supported payload version and discriminator.
- Malformed, oversized, unknown, unauthorized, and replayed payloads.
- Source, destination, and Session ID consistency.
- Dispatcher routing and handler isolation.
- Acknowledgement-loop prevention.
- Deterministic clocks, rate limits, and resource bounds.
- Mixed Control, Data, and Blackboard fairness through injected transports.

These tests must not require Bonjour, Network.framework listeners, Local Network permission, Keychain access, or code signing.

### Deterministic cross-module tests

Use `BeakrNetTestSupport` and the handoff laboratory to prove that typed Control payloads preserve their exact envelope identity across relay/LAN promotion, ambiguous retry, duplicate suppression, cross-route acknowledgement, expiry, and relay fallback.

### Apple integration tests

Keep Apple networking and security behavior in the existing opt-in integration layers:

- The SwiftPM Apple integration target covers real macOS Bonjour, listeners, connections, framing, and path loss where the host permits them.
- `BeakrNetIntegrationHost` and its `BeakrNetIntegrationTests` target supply the signed macOS, Simulator, and physical-device host for Local Network permission, mutual TLS, Keychain, and sandbox behavior.

Milestone 6 should add only enough signed-host coverage to prove that a typed Control message crosses a real authenticated connection and dispatches once. Payload codec and dispatcher edge cases belong in pure tests.

## Required validation for Milestone 6

Before closure:

1. Run the complete package suite with `swift test --disable-sandbox`.
2. Run the focused `BeakrNetControlTests` suite.
3. Run the relay/LAN handoff laboratory coverage.
4. Run the opt-in macOS Apple-network integration test where supported.
5. Run the signed Control end-to-end test on at least one Simulator or physical device.
6. Report skipped tests and environmental limitations separately from product failures.

The package suite remains the primary regression gate. Signed Apple tests establish platform behavior but do not replace deterministic protocol tests.
