# Authority-Managed Network Capabilities

## Status and scope

This document records a future architecture direction agreed during Release 1 hands-on testing. It does not expand Release 1 scope. Release 1 continues using its current fixed service and security behavior until its existing test requirements are stable; provider selection remains deferred.

## Authority-owned network policy

The network authority defines what a network supports and requires. Authority-managed policy may eventually include:

- Enabled application services, such as messaging, file transfer, presence, or synchronization.
- Required encryption protocols and permitted encryption providers.
- Permitted or preferred compression formats and providers.
- Minimum compatible protocol and provider versions.
- Explicit fallback rules.

Member devices do not independently weaken or replace network policy. They advertise their supported capabilities, compare them with the authority's requirements, and participate only where the requirements can be satisfied.

## Three distinct views of capability

The design must keep these concepts separate:

1. **Available providers** are implementations installed and usable on a particular device.
2. **Network policy** is the authority-defined set of required or permitted services, algorithms, providers, and versions.
3. **Negotiated configuration** is the compatible configuration actually selected for a connection or operation.

A member-facing interface should display:

- What the network requires or permits.
- What the local device supports.
- What was negotiated for the active connection.
- Any incompatibility preventing connection or a particular service.

## Configuration ownership and interface placement

- Application-service enablement belongs to the individual network's authority-managed parameters.
- Provider installation and device-wide availability belong to application or device settings.
- Compression policy and provider selection belong to a future transport or data-handling area in Network Parameters.
- Encryption requirements and provider policy belong to a future security area in Network Parameters and must not be presented as an optional application service.
- The active negotiated compression and encryption configuration may be displayed read-only with connection status.

The existing Services row represents application functionality. It should become a disclosure group only when multiple application services or meaningful per-service details exist.

## Custom provider direction

Custom compression and encryption providers are a desirable future extension. A provider system requires:

- Stable provider identifiers, algorithm identifiers, and versions.
- Capability negotiation before protected communication begins.
- Authenticated or signed provider distribution and an explicit trust policy.
- Known-answer, compatibility, and interoperability tests.
- Clear migration, deprecation, and recovery behavior.
- Deterministic behavior when a required provider is unavailable.
- Explicit downgrade rules; encryption must never silently downgrade.

Provider extensibility must preserve BeakrNet's network isolation, authentication, canonical protocol encoding, and fail-closed security behavior.

## Deferred work

Before implementation, a later milestone must define the provider protocol, authority policy schema, negotiation transcript, persistence model, administrative interface, member-facing compatibility display, and migration strategy. No provider-selection interface should be added during Release 1 stabilization.
