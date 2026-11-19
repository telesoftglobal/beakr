#if os(macOS)
import Foundation
import Darwin
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite(
    "Authority HTTPS server integration",
    .enabled(if: ProcessInfo.processInfo.environment["BEAKRNET_RUN_AUTHORITY_HTTPS_INTEGRATION"] == "1"),
    .serialized
)
struct AuthorityHTTPSServerIntegrationTests {
    @Test("Real TLS authority requests recover after loopback delay and connection interruption", .timeLimit(.minutes(3)))
    func realTLSControlPlane() async throws {
        let environment = ProcessInfo.processInfo.environment
        let serverURL = try #require(environment["BEAKRNET_AUTHORITY_SERVER_EXECUTABLE"])
        let opensslURL = environment["BEAKRNET_OPENSSL_PATH"] ?? "/usr/bin/openssl"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-authority-https-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let caKey = root.appendingPathComponent("ca.key")
        let caCertificate = root.appendingPathComponent("ca.pem")
        let serverKey = root.appendingPathComponent("server.key")
        let serverRequest = root.appendingPathComponent("server.csr")
        let serverCertificate = root.appendingPathComponent("server.pem")
        let serverExtensions = root.appendingPathComponent("server.ext")
        let serverIdentity = root.appendingPathComponent("server.p12")
        try Data("subjectAltName=DNS:authority.test\nextendedKeyUsage=serverAuth\n".utf8)
            .write(to: serverExtensions, options: .atomic)
        try run(opensslURL, [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-sha256", "-days", "2", "-subj", "/CN=Beakr Test CA",
            "-keyout", caKey.path, "-out", caCertificate.path
        ])
        try run(opensslURL, [
            "req", "-newkey", "rsa:2048", "-nodes",
            "-subj", "/CN=authority.test", "-addext", "subjectAltName=DNS:authority.test",
            "-keyout", serverKey.path, "-out", serverRequest.path
        ])
        try run(opensslURL, [
            "x509", "-req", "-in", serverRequest.path, "-CA", caCertificate.path,
            "-CAkey", caKey.path, "-CAcreateserial", "-days", "2", "-sha256",
            "-extfile", serverExtensions.path, "-out", serverCertificate.path
        ])
        let password = UUID().uuidString
        try run(opensslURL, [
            // Use the broadly interoperable PKCS#12 protection algorithms
            // accepted by Apple Security instead of OpenSSL 3's defaults.
            "pkcs12", "-export",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            "-inkey", serverKey.path, "-in", serverCertificate.path,
            "-certfile", caCertificate.path, "-passout", "pass:\(password)",
            "-out", serverIdentity.path
        ])

        let authority = CredentialAuthority()
        let authorityPrivate = root.appendingPathComponent("authority.private")
        let authorityPublic = root.appendingPathComponent("authority.public")
        try CredentialFiles.saveAuthority(
            authority,
            privateKeyURL: authorityPrivate,
            publicKeyURL: authorityPublic
        )
        let networkID = NetworkID()
        let port = Int.random(in: 49_152...65_535)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverURL)
        process.arguments = [
            String(port), serverIdentity.path, authorityPrivate.path,
            root.appendingPathComponent("trust.json").path, networkID.rawValue.uuidString,
            "test", opensslURL, caCertificate.path, caKey.path
        ]
        process.environment = environment.merging([
            "BEAKRNET_AUTHORITY_TLS_PASSWORD": password
        ]) { _, new in new }
        let serverOutput = Pipe()
        process.standardOutput = serverOutput
        process.standardError = serverOutput
        try process.run()
        defer {
            terminate(process)
        }

        let transport = CurlAuthorityTransport(
            baseURL: URL(string: "https://authority.test:\(port)")!,
            caCertificate: caCertificate,
            directory: root
        )
        do {
            try await waitUntilReady(transport)
        } catch {
            if !process.isRunning {
                let output = serverOutput.fileHandleForReading.readDataToEndOfFile()
                throw AuthorityHTTPSIntegrationError.commandFailed(String(decoding: output, as: UTF8.self))
            }
            throw error
        }
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: Date()
        )
        let client = try CertificateEnrollmentNetworkClient(
            transport: transport,
            identity: identity,
            credential: credential,
            environment: "test",
            requestedValidity: 600
        )
        let exchange = try await client.renewCertificate()
        try CertificateEnrollmentResponseVerifier.verify(
            exchange.response,
            for: exchange.request,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation
        )
        let membership = try await ProfileMembershipNetworkClient(transport: transport)
            .fetchSnapshot(after: nil)
        #expect(membership?.claims.records.first?.credential == credential)
        let revocations = try await RevocationSnapshotNetworkClient(transport: transport)
            .fetchSnapshot(after: nil)
        #expect(revocations?.claims.revocations.isEmpty == true)

        // Forward encrypted TCP bytes only. The client still validates the real
        // authority certificate; the proxy never terminates or weakens TLS.
        let modeFile = root.appendingPathComponent("proxy-mode")
        let portFile = root.appendingPathComponent("proxy-port")
        let eventFile = root.appendingPathComponent("proxy-events")
        let scriptFile = root.appendingPathComponent("proxy.py")
        try Data("baseline".utf8).write(to: modeFile, options: .atomic)
        try Data(loopbackProxyScript.utf8).write(to: scriptFile)
        let proxy = Process()
        proxy.executableURL = URL(fileURLWithPath: environment["BEAKRNET_TEST_PYTHON"] ?? "/usr/bin/python3")
        proxy.arguments = [scriptFile.path, String(port), modeFile.path, portFile.path, eventFile.path]
        proxy.standardOutput = FileHandle.nullDevice
        proxy.standardError = FileHandle.nullDevice
        try proxy.run()
        defer { terminate(proxy) }
        var proxyPort: Int?
        for _ in 0..<50 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let value = Int(text) {
                proxyPort = value
                break
            }
            guard proxy.isRunning else { throw AuthorityHTTPSIntegrationError.serverNotReady }
            try await Task.sleep(for: .milliseconds(100))
        }
        let listeningPort = try #require(proxyPort)
        let proxyURL = try #require(URL(string: "https://authority.test:\(listeningPort)"))
        let proxyTransport = CurlAuthorityTransport(
            baseURL: proxyURL,
            caCertificate: caCertificate, directory: root
        )
        let membershipClient = ProfileMembershipNetworkClient(transport: proxyTransport)
        let baseline = try #require(try await membershipClient.fetchSnapshot(after: nil))
        try ProfileMembershipVerifier.verify(baseline, networkID: networkID, environment: "test",
                                             trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                                             revokedCredentialIDs: [])
        #expect(baseline == membership)

        try Data("delay".utf8).write(to: modeFile, options: .atomic)
        let clock = ContinuousClock()
        let start = clock.now
        let delayed = try await membershipClient.fetchSnapshot(after: nil)
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(250))
        #expect(delayed == baseline)
        print("E11 TLS loopback: configured initial client-byte delay=250ms, request elapsed=\(elapsed)")

        try Data("interrupt".utf8).write(to: modeFile, options: .atomic)
        do {
            _ = try await membershipClient.fetchSnapshot(after: nil)
            Issue.record("Interrupted TLS connection must not return membership")
        } catch AuthorityHTTPSIntegrationError.commandFailed {
            // curl must fail: this cut occurs on the first server TLS bytes,
            // before an authenticated HTTP response can be received.
        }
        try Data("baseline".utf8).write(to: modeFile, options: .atomic)
        let recovered = try #require(try await membershipClient.fetchSnapshot(after: nil))
        #expect(recovered == baseline)
        try ProfileMembershipVerifier.verify(recovered, networkID: networkID, environment: "test",
                                             trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                                             revokedCredentialIDs: [])
        let recoveredRevocations = try #require(try await RevocationSnapshotNetworkClient(transport: proxyTransport)
            .fetchSnapshot(after: nil))
        #expect(recoveredRevocations == revocations)
        _ = try RevocationVerifier.verify(recoveredRevocations, trustedAuthorityPublicKey: authority.publicKeyRepresentation)
        let events = try String(contentsOf: eventFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(events.filter { $0 == "accepted:baseline" }.count == 3)
        #expect(events.filter { $0 == "accepted:delay" }.count == 1)
        #expect(events.filter { $0 == "accepted:interrupt" }.count == 1)
        #expect(events.filter { $0 == "cut:server-tls-bytes" }.count == 1)
        print("E11 TLS loopback: five client connections, one deliberate TLS interruption, signed state recovered")
    }

    private func waitUntilReady(_ transport: CurlAuthorityTransport) async throws {
        for _ in 0..<40 {
            if let response = try? await transport.send(.init(
                method: "GET", path: ProfileMembershipHTTPEndpoint.path
            )), response.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AuthorityHTTPSIntegrationError.serverNotReady
    }
}

actor CurlAuthorityTransport: CertificateEnrollmentHTTPTransport {
    let baseURL: URL
    let caCertificate: URL
    let directory: URL

    init(baseURL: URL, caCertificate: URL, directory: URL) {
        self.baseURL = baseURL
        self.caCertificate = caCertificate
        self.directory = directory
    }

    func send(_ request: CertificateEnrollmentHTTPRequest) async throws -> CertificateEnrollmentHTTPResponse {
        let token = UUID().uuidString
        let requestBody = directory.appendingPathComponent("request-\(token)")
        let responseBody = directory.appendingPathComponent("response-\(token)")
        let responseHeaders = directory.appendingPathComponent("headers-\(token)")
        defer {
            try? FileManager.default.removeItem(at: requestBody)
            try? FileManager.default.removeItem(at: responseBody)
            try? FileManager.default.removeItem(at: responseHeaders)
        }
        try request.body.write(to: requestBody)
        var arguments = [
            "--silent", "--show-error", "--noproxy", "*",
            "--connect-timeout", "1", "--max-time", "3",
            "--cacert", caCertificate.path,
            "--resolve", "authority.test:\(baseURL.port!):127.0.0.1",
            "--request", request.method,
            "--dump-header", responseHeaders.path,
            "--output", responseBody.path,
            "--write-out", "%{http_code}"
        ]
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            arguments += ["--header", "\(name): \(value)"]
        }
        if !request.body.isEmpty { arguments += ["--data-binary", "@\(requestBody.path)"] }
        arguments.append(baseURL.appendingPathComponent(request.path).absoluteString)
        let statusText = try run("/usr/bin/curl", arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = Int(statusText) else { throw AuthorityHTTPSIntegrationError.invalidResponse }
        let headerText = try String(contentsOf: responseHeaders, encoding: .utf8)
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return .init(
            statusCode: status,
            headers: headers,
            body: (try? Data(contentsOf: responseBody)) ?? Data()
        )
    }
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw AuthorityHTTPSIntegrationError.commandFailed(String(decoding: data, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
}

private func terminate(_ process: Process) {
    guard process.isRunning else {
        process.waitUntilExit()
        return
    }
    process.terminate()
    for _ in 0..<20 {
        if !process.isRunning { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}

private enum AuthorityHTTPSIntegrationError: Error {
    case serverNotReady
    case invalidResponse
    case commandFailed(String)
}

// Python is test infrastructure only; no system packet filters or live LAN ports.
private let loopbackProxyScript = #"""
import pathlib, select, socket, sys, threading, time
upstream_port = int(sys.argv[1])
mode_file, port_file, event_file = map(pathlib.Path, sys.argv[2:])
lock = threading.Lock()
def record(event):
    with lock:
        with event_file.open("a") as output:
            output.write(event + "\n")
def forward(client, mode):
    upstream = None
    try:
        client.settimeout(1)
        upstream = socket.create_connection(("127.0.0.1", upstream_port), timeout=1)
        first_client_bytes = True
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            readable, _, _ = select.select([client, upstream], [], [], 0.2)
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                if source is upstream and mode == "interrupt":
                    record("cut:server-tls-bytes")
                    return
                if source is client and first_client_bytes:
                    first_client_bytes = False
                    if mode == "delay":
                        time.sleep(0.250)
                target = upstream if source is client else client
                target.sendall(data)
    except OSError:
        pass
    finally:
        client.close()
        if upstream is not None:
            upstream.close()
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
listener.settimeout(0.2)
port_file.write_text(str(listener.getsockname()[1]))
deadline = time.monotonic() + 60
try:
    while time.monotonic() < deadline:
        try:
            client, _ = listener.accept()
        except socket.timeout:
            continue
        mode = mode_file.read_text()
        record("accepted:" + mode)
        threading.Thread(target=forward, args=(client, mode), daemon=True).start()
finally:
    listener.close()
"""#
#endif
