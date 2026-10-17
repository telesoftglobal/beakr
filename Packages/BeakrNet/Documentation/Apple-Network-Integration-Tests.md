# Apple Network Integration Tests

`BeakrNetAppleIntegrationTests` is a separate SwiftPM target for behavior that pure unit tests cannot establish. It uses a real `NWListener`, `NWBrowser`, Bonjour advertisement/discovery, TLS connection establishment, Network-framework frame I/O, and the authenticated BeakrNet LAN handshake.

The target is opt-in because it needs Apple networking services, multicast DNS, Local Network permission, and a host that permits listeners. Its tests remain skipped during ordinary `swift test`, keeping unit tests independent of host networking policy.

The same target also contains a macOS-only integration test for `OpenSSLDevelopmentCertificateIssuer`. It creates an ephemeral P-256 authority, issues a leaf for a real `NodeIdentity`, verifies the certificate chain with OpenSSL, checks the leaf key through Security.framework, and removes all generated material.

It also contains an opt-in loopback test for the `BeakrNetAuthorityServer` executable. That test generates a disposable CA and TLS identity, launches the real TLS 1.3 listener, and delivers certificate enrollment, membership, and revocation requests through the bounded HTTP codec and authority router.

## Local run

```sh
cd Packages/BeakrNet
swift test --disable-sandbox
BEAKRNET_RUN_APPLE_NETWORK_INTEGRATION=1 swift test --disable-sandbox \
  --filter BeakrNetAppleIntegrationTests
BEAKRNET_RUN_CERTIFICATE_ISSUER_INTEGRATION=1 swift test --disable-sandbox \
  --filter OpenSSLCertificateIssuerIntegrationTests
swift build --disable-sandbox --product BeakrNetAuthorityServer
BEAKRNET_RUN_AUTHORITY_HTTPS_INTEGRATION=1 \
BEAKRNET_AUTHORITY_SERVER_EXECUTABLE="$PWD/.build/debug/BeakrNetAuthorityServer" \
BEAKRNET_OPENSSL_PATH=/opt/homebrew/bin/openssl \
swift test --disable-sandbox --filter AuthorityHTTPSServerIntegrationTests
```

Run on macOS. The first run may prompt for Local Network access. A denial, disabled multicast DNS, a firewall, VPN filtering, or a locked-down runner can prevent discovery. The test uses bounded waits and always cancels its browser, listener, connections, and transports.

The fixture uses the existing development relay PSK configuration for a real TLS channel. It supplies deterministic certificate metadata through the `BonjourConnection` test seam so `LANTransport` verifies credential/key and fingerprint binding. Generating and installing `SecIdentity` fixtures would add keychain and code-signing state to a package test. Production mutual-certificate trust evaluation must additionally be covered by a signed app-hosted test when identity provisioning is implemented.

Permission denial is surfaced by the adapters as `permissionDenied`, and connection loss by `LANTransport` as `pathLost`. Permission denial is not forced automatically because Local Network authorization is process-level OS state. Validate it manually by revoking access for the signed test host.

## CI

Use a dedicated macOS runner with Bonjour/mDNS and local listeners enabled. Set `BEAKRNET_RUN_APPLE_NETWORK_INTEGRATION=1`, run the filtered command, and retain the test log. Do not enable it on generic runners unless they explicitly support multicast DNS.

The certificate-issuer integration test does not need Bonjour or Local Network permission, but it does require macOS and an OpenSSL executable. It checks `BEAKRNET_TEST_OPENSSL` first, then common Homebrew and system locations. Set `BEAKRNET_RUN_CERTIFICATE_ISSUER_INTEGRATION=1` on a macOS CI runner; set `BEAKRNET_TEST_OPENSSL` when OpenSSL is installed elsewhere.

The authority HTTPS test requires macOS, the separately built authority executable, Homebrew OpenSSL 3, loopback listeners, and an available macOS Security/Keychain service. The generated PKCS #12 uses explicit interoperable protection algorithms; the TLS connection itself remains TLS 1.3. Run it from standalone-package Xcode or an unrestricted signed-host shell. Sandboxed or headless automation can make `SecPKCS12Import` fail with `errSecInternalComponent` (`-26276`); that indicates the host Security service is unavailable to the test process, not a certificate parse failure. All readiness, curl, and process-shutdown waits are bounded, including forced cleanup after a failed launch.

Set `BEAKRNET_RUN_KEYCHAIN_IDENTITY_INTEGRATION=1` alongside the issuer flag only on a signed macOS test host with an available Keychain. Unsigned or headless command-line processes can receive `errSecNotAvailable`; this is a host limitation rather than an issuer failure.

Simulator/device CI requires a signed test host with `NSLocalNetworkUsageDescription` and `_beakrtest._tcp` in `NSBonjourServices`; command-line SwiftPM tests have no app `Info.plist` for iOS-family authorization.

## Signed mutual-TLS host

The dedicated `BeakrNetIntegrationHost` project contains the hosted `BeakrNetIntegrationTests` target and its checked-in `BeakrNetIntegrationTests.xctestplan`. The host has Local Network usage text, declares the BeakrNet Bonjour services, and permits signed inbound and outbound sandbox connections. It contains no product networking implementation; it imports and verifies the `BeakrNet` package products under Apple signing, sandbox, Keychain, and Local Network conditions.

The mutual-TLS test is opt-in and expects externally provisioned, test-only fixtures:

- `BEAKRNET_RUN_SIGNED_MTLS_INTEGRATION=1`
- `BEAKRNET_TEST_PKCS12_PASSWORD`
- `BEAKRNET_TEST_CLIENT_PKCS12`: path to the client identity
- `BEAKRNET_TEST_SERVER_PKCS12`: path to the server identity
- `BEAKRNET_TEST_EXPIRED_SERVER_PKCS12`: path to a zero-day server identity used by rejection tests
- `BEAKRNET_TEST_AUTHORITY_DER`: path to the issuing authority certificate
- `BEAKRNET_TEST_WRONG_AUTHORITY_DER`: path to an unrelated authority used by rejection tests

Both PKCS #12 files must contain P-256 identities issued by the supplied authority. Configure those environment variables in the `BeakrNetIntegrationTests` test plan, select the `BeakrNetIntegrationHost` scheme and a macOS or iOS-family destination, and run the `Signed LAN mutual TLS integration` suite. The checked-in opt-in entry is disabled by default so ordinary tests remain credential-free. The suite creates a real listener and connection using `LANTLSConfiguration`, requires both endpoints to reach TLS-ready state, transfers data, verifies both peer certificate chains are available, and cancels all resources. It also installs matching leaf and chain material through `KeychainLANTLSIdentityStore`, reloads the selected identity, and verifies that a rejected replacement leaves the previous identity active. Its lifecycle case verifies an authority-signed enrollment response, installs it in the real Keychain, recreates the store to model an app restart, then processes a second signed exchange through `CertificateRenewalScheduler` and confirms the identity remains loadable.

CI should inject the fixture files and password from its secret store into a temporary directory, run the test, and remove that directory afterward. Never add PKCS #12 files or their password to the repository. Without the opt-in variable, the test is skipped so ordinary app builds and tests do not depend on external credentials.

For a local macOS run, the repository includes a test-only generator and wrapper:

```sh
Scripts/run-signed-mtls-integration.sh
```

Pass an Xcode destination as the first argument for another Apple platform:

```sh
Scripts/run-signed-mtls-integration.sh \
  "platform=iOS Simulator,name=iPhone 17 Pro"
```

The generator requires OpenSSL, creates a 30-day P-256 test authority, an unrelated rejection-test authority, and two 30-day identities with digital-signature key usage plus client/server EKUs. It verifies the chains and PKCS #12 bundles and writes them with owner-only permissions under a temporary directory. The environment includes both host paths and base64 values; the latter allow Simulator and device test processes to consume fixtures without host-filesystem access. The wrapper exports the fixture environment only to its process, runs the hosted Xcode tests, and deletes the temporary directory on exit.

To inspect or reuse fixtures for an Xcode destination, generate them into a new or empty directory and source the resulting owner-only environment file:

```sh
Scripts/generate-lan-tls-test-fixtures.sh /path/to/empty-directory
source /path/to/empty-directory/environment.sh
```

These are disposable integration credentials, not development or production enrollment artifacts.

## Verified destinations

On October 3, 2026, the enabled signed-host suite completed successfully on macOS, iOS Simulator, and a physical iPhone. The physical-device run verified code signing, installation, Security and Network framework behavior, and Local Network authorization with the real iOS sandbox. Together the runs covered successful mutual TLS 1.3 and encrypted transfer plus rejection of an unrelated authority, an expired leaf, and a client without an identity.
