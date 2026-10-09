import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSH
import NIOSSL
import PostgresNIO
import Testing

@testable import Dblore

/// Live tests against docker/postgresql/docker-compose.ssh.yml.
@Suite("SSH tunnel integration", .requiresSSHPostgres, .serialized)
struct SSHTunnelIntegrationTests {
  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docker/postgresql/data/ssh", isDirectory: true)

  private static let sshPort = 2222
  private static let rsaOnlySSHPort = 2223
  private static let password = "dblore-ssh-123"

  private static func expectedFingerprint() throws -> String {
    try String(
      contentsOf: fixtures.appendingPathComponent("host_fingerprint.txt"), encoding: .utf8
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func connect(
    port: Int = sshPort, password: String = password,
    authentication: SSHTunnelAuthentication? = nil,
    validator: @escaping SSHHostKeyValidator = { _, _ in }
  ) async throws -> SSHTunnel {
    try await withTimeout {
      try await SSHTunnel.connect(
        host: "127.0.0.1", port: port, username: "dblore",
        authentication: authentication ?? .password(password), hostKeyValidator: validator)
    }
  }

  private static func postgres(
    over tunnel: SSHTunnel, tls: PostgresConnection.Configuration.TLS
  ) async throws -> PostgresConnection {
    let channel = try await withTimeout {
      try await tunnel.openDirectTCPIP(targetHost: "postgres", targetPort: 5432)
    }
    let configuration = PostgresConnection.Configuration(
      establishedChannel: channel, tls: tls, username: "dblore_ssh", password: "dblore123",
      database: "dblore_ssh")
    return try await withTimeout {
      try await PostgresConnection.connect(
        on: channel.eventLoop, configuration: configuration, id: 1,
        logger: Logger(label: "ssh-tunnel-tests"))
    }
  }

  private static func selectOne(_ connection: PostgresConnection) async throws -> Int {
    let rows = try await connection.query("SELECT 1::int4 AS one", logger: Logger(label: "q"))
    var values: [Int] = []
    for try await value in rows.decode(Int.self) { values.append(value) }
    return values.first ?? -1
  }

  /// Completes when the connection's channel closes. Registered synchronously, so it still
  /// fires when the event loop shuts down right after the close.
  private static func closeSignal(of connection: PostgresConnection) -> Task<Void, Never> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    connection.closeFuture.whenComplete { _ in continuation.finish() }
    return Task { for await _ in stream {} }
  }

  @Test func passwordAuthReportsHostFingerprint() async throws {
    let seen = FingerprintBox()
    let tunnel = try await Self.connect { _, fingerprint in seen.set(fingerprint) }
    await tunnel.close()
    #expect(seen.value == (try Self.expectedFingerprint()))
  }

  @Test(arguments: [("id_ed25519", nil), ("id_ecdsa", nil), ("id_ed25519_enc", "dblore-pass")])
  func privateKeyAuthRunsPostgresOverTunnel(keyFile: String, passphrase: String?) async throws {
    let key = try SSHPrivateKeyParser.parse(
      Data(contentsOf: Self.fixtures.appendingPathComponent(keyFile)), passphrase: passphrase)
    let tunnel = try await Self.connect(authentication: .privateKey(key.privateKey))
    let connection = try await Self.postgres(over: tunnel, tls: .disable)
    #expect(try await Self.selectOne(connection) == 1)
    try await connection.close()
    await tunnel.close()
  }

  @Test func openingAChannelAfterCloseFails() async throws {
    let tunnel = try await Self.connect()
    await tunnel.close()
    await #expect(throws: SSHTunnelError.closedBeforeReady) {
      _ = try await withTimeout(seconds: 5) {
        try await tunnel.openDirectTCPIP(targetHost: "postgres", targetPort: 5432)
      }
    }
  }

  @Test func rejectedHostKeyFailsTheConnection() async throws {
    await #expect(throws: SSHTunnelError.hostKeyRejected) {
      _ = try await Self.connect { _, _ in throw SSHTunnelError.hostKeyRejected }
    }
  }

  @Test func postgresRunsOverTunnelWithoutTLS() async throws {
    let tunnel = try await Self.connect()
    let connection = try await Self.postgres(over: tunnel, tls: .disable)
    #expect(try await Self.selectOne(connection) == 1)
    try await connection.close()
    await tunnel.close()
  }

  @Test func postgresRunsOverTunnelWithRequiredTLS() async throws {
    let certificate = try NIOSSLCertificate.fromPEMFile(
      Self.fixtures.appendingPathComponent("postgres/server.crt").path)
    var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
    tlsConfiguration.trustRoots = .certificates(certificate)
    tlsConfiguration.certificateVerification = .noHostnameVerification
    let context = try NIOSSLContext(configuration: tlsConfiguration)

    let tunnel = try await Self.connect()
    let connection = try await Self.postgres(over: tunnel, tls: .require(context))
    let rows = try await connection.query(
      "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", logger: Logger(label: "q"))
    var usesSSL: [Bool] = []
    for try await value in rows.decode(Bool.self) { usesSSL.append(value) }
    #expect(usesSSL == [true])
    try await connection.close()
    await tunnel.close()
  }

  @Test func closingTunnelClosesPostgresConnection() async throws {
    let tunnel = try await Self.connect()
    let connection = try await Self.postgres(over: tunnel, tls: .disable)
    #expect(try await Self.selectOne(connection) == 1)
    // Observe before closing: the tunnel shuts down its own event loop on close.
    let closed = Self.closeSignal(of: connection)
    await tunnel.close()
    // close() returns only after child channels closed.
    #expect(connection.isClosed)
    try await withTimeout(seconds: 5) { await closed.value }
    #expect(connection.isClosed)
  }

  @Test func openRacingCloseAlwaysCompletes() async throws {
    // The tunnel owns its loop here: an open that reached the loop after close() shut it
    // down would hang. Jitter on both sides so either one may win.
    for iteration in 0..<50 {
      let tunnel = try await Self.connect()
      let open = Task {
        try? await Task.sleep(for: .microseconds(Int.random(in: 0...500)))
        return try await withTimeout(seconds: 10) {
          try await tunnel.openDirectTCPIP(targetHost: "postgres", targetPort: 5432)
        }
      }
      // Wider on the close side: the open waits for sshd to connect to Postgres (tens of ms
      // here), so a shorter range never lets the open win.
      try? await Task.sleep(for: .microseconds(Int.random(in: 0...100_000)))
      try await withTimeout(seconds: 10) { await tunnel.close() }
      switch await open.result {
      case .success(let channel):
        #expect(!channel.isActive, "iteration \(iteration): open returned a live channel")
      case .failure(let error):
        #expect(
          error as? SSHTunnelError == .closedBeforeReady, "iteration \(iteration): \(error)")
      }
    }
  }

  @Test func serverDroppingTunnelClosesPostgresConnection() async throws {
    let tunnel = try await Self.connect()
    let connection = try await Self.postgres(over: tunnel, tls: .disable)
    // Simulate the network dropping: close only the TCP socket under the SSH session.
    let closed = Self.closeSignal(of: connection)
    try await tunnel.parentChannel.close()
    try await withTimeout(seconds: 5) { await closed.value }
    #expect(connection.isClosed)
    await tunnel.close()
  }

  @Test func rsaOnlyHostFailsWithClearError() async throws {
    await #expect(throws: SSHTunnelError.unsupportedHostKeyAlgorithm) {
      _ = try await Self.connect(port: Self.rsaOnlySSHPort)
    }
  }

  @Test func wrongPasswordFailsAuthentication() async throws {
    await #expect(throws: SSHTunnelError.authenticationFailed) {
      _ = try await Self.connect(password: "wrong-password")
    }
  }
}

// MARK: - Reconnect paths through DatabaseConnectionManager (phase 8.4)
// Every live reconnect path rebuilds the SSH tunnel: cancel, capped-read reset, session loss
// (the parent SSH channel closed through the spy, since the sandboxed test host cannot restart
// docker) followed by the banner's reconnect, and the probe. After each one only the current
// tunnel is open.
//
// Each test pins the bastion through the real `SSHHostKeyPolicy` and a confirming prompt, in
// its own in-memory known-host store: the shared store is also written by
// `PostgresSSHTunnelLifecycleTests` (a wrong pin, removals), and suites run in parallel.

@MainActor
extension SSHTunnelIntegrationTests {
  private static let bastionHost = "127.0.0.1"
  private static let bastionPort = 2222
  private var open: ProtectionPolicy { ProtectionPolicy(protectionLevel: .none) }

  private static func config() -> ConnectionConfig {
    ConnectionConfig(
      host: "postgres", port: 5432, database: "dblore_ssh", username: "dblore_ssh",
      password: "dblore123", sslMode: .disable,
      sshTunnel: SSHTunnelConfig(host: bastionHost, port: bastionPort, username: "dblore"),
      timeoutSeconds: 15, safeMode: .silent, protectedMode: false,
      statementTimeoutSeconds: 120)
  }

  /// A manager whose sessions tunnel through `spy` and trust the bastion only after `prompt`
  /// confirmed it into `store`.
  @MainActor
  private struct Harness {
    let spy = SpySSHTunnelFactory()
    let store = InMemorySSHKnownHostStore()
    let prompt = FakeSSHHostKeyPrompt(answer: true)
    let config = SSHTunnelIntegrationTests.config()

    var policy: SSHHostKeyPolicy { SSHHostKeyPolicy(store: store, prompt: prompt) }

    func makeManager() -> DatabaseConnectionManager {
      let account = SSHCredentialStoreFactory.account(for: config)!
      SSHCredentialStoreFactory.shared.save(.password("dblore-ssh-123"), account: account)
      return DatabaseConnectionManager(
        sessionFactory: SpyPostgresSessionFactory(tunnelFactory: spy, hostKeyValidator: policy),
        sshHostKeyPrompt: prompt)
    }

    /// The bastion was confirmed once and pinned; later tunnels reused the pin.
    func expectPinnedOnce() {
      #expect(prompt.requests.count == 1)
      #expect((try? store.lookup(host: bastionHost, port: bastionPort)) != nil)
    }

    /// Every tunnel but the newest is closed and its SSH connection gone; the newest is open.
    func expectOnlyLatestOpen(count: Int) {
      #expect(spy.tunnels.count == count)
      #expect(spy.tunnels.dropLast().allSatisfy { $0.isTornDown })
      #expect(spy.tunnels.last.map { !$0.isClosed && $0.parentChannel.isActive } == true)
    }

    func tearDown(_ manager: DatabaseConnectionManager) async {
      await manager.disconnect()
      #expect(
        await SSHTunnelIntegrationTests.eventually { spy.tunnels.allSatisfy { $0.isTornDown } })
      store.remove(host: bastionHost, port: bastionPort)
    }
  }

  private static func selectOneValue(
    _ manager: DatabaseConnectionManager
  ) async throws -> CellValue? {
    try await manager.execute(userSQL: "SELECT 1", policy: ProtectionPolicy(protectionLevel: .none))
      .rows.first?.first
  }

  private static func backendPid(_ manager: DatabaseConnectionManager) async throws -> Int {
    let value = try await manager.executeInternal("SELECT pg_backend_pid()").rows.first?.first
    guard case .int(let pid) = value else { throw DatabaseError.queryFailed("no backend pid", 0) }
    return pid
  }

  /// Poll `condition` every 50 ms for up to `seconds`
  private static func eventually(
    within seconds: Double = 5, _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
  }

  @Test(
    "Cancel of pg_sleep(30) reconnects through a new tunnel and closes the old one",
    .timeLimit(.minutes(1)))
  func cancelRebuildsTunnel() async throws {
    let harness = Harness()
    let manager = harness.makeManager()
    try await manager.connect(config: harness.config)
    let pid = try await Self.backendPid(manager)
    let policy = open
    let running = Task {
      await bounded(.seconds(15)) {
        _ = try await manager.execute(userSQL: "SELECT pg_sleep(30)", policy: policy)
      }
    }
    #expect(await Self.eventually { await manager.runningStatementStatus().inFlight })
    // inFlight is counted before the query reaches the server; let it start.
    try await Task.sleep(for: .milliseconds(300))
    let status = await manager.runningStatementStatus()
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    let statement = await running.value
    guard case .threw(let error) = statement, case .queryCancelled? = error as? DatabaseError
    else {
      Issue.record("Expected queryCancelled, got \(statement)")
      await harness.tearDown(manager)
      return
    }

    #expect(await manager.isConnected)
    #expect(try await Self.selectOneValue(manager) == .int(1))
    #expect(try await Self.backendPid(manager) != pid)
    // The old backend ends once the server sees its client gone (closed SSH channel).
    let backendGone = await Self.eventually {
      let count = try? await manager.executeInternal(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = \(pid)")
      return count?.rows.first?.first == .int(0)
    }
    #expect(backendGone, "backend \(pid) still runs pg_sleep after cancel")
    harness.expectOnlyLatestOpen(count: 2)
    harness.expectPinnedOnce()
    await harness.tearDown(manager)
  }

  @Test(
    "A capped-read reset reconnects through a new tunnel and closes the old one",
    .timeLimit(.minutes(1)))
  func cappedReadRebuildsTunnel() async throws {
    let harness = Harness()
    let manager = harness.makeManager()
    try await manager.connect(config: harness.config)
    let read = try await manager.execute(
      userSQL: "SELECT oid FROM pg_catalog.pg_class", policy: open, maxRows: 10)
    #expect(read.sessionReset)
    #expect(read.rows.count == 10)
    #expect(try await Self.selectOneValue(manager) == .int(1))
    harness.expectOnlyLatestOpen(count: 2)
    harness.expectPinnedOnce()
    await harness.tearDown(manager)
  }

  @Test(
    "A dropped SSH connection is reported lost; Reconnect opens a new tunnel",
    .timeLimit(.minutes(1)))
  func sessionLossThenReconnect() async throws {
    let harness = Harness()
    let manager = harness.makeManager()
    try await manager.connect(config: harness.config)
    let first = try #require(harness.spy.tunnels.last)
    let events = manager.sessionEvents
    let lost = Task {
      await bounded(.seconds(10)) {
        for await _ in events { return }
      }
    }
    try await first.parentChannel.close()
    let outcome = await lost.value
    guard case .returned = outcome else {
      Issue.record("No session-lost event: \(outcome)")
      await harness.tearDown(manager)
      return
    }
    #expect(await !manager.isConnected)
    #expect(await manager.lastSessionLoss != nil)
    // `markSessionLost` closes the forgotten tunnel in a detached task.
    #expect(await Self.eventually { first.isTornDown })

    // Banner Reconnect: `connect` with the workspace config (no client certificate here).
    try await manager.reconnectWithActiveCertificate(config: harness.config, material: nil)
    #expect(try await Self.selectOneValue(manager) == .int(1))
    harness.expectOnlyLatestOpen(count: 2)
    harness.expectPinnedOnce()
    await harness.tearDown(manager)
  }

  /// `testConnection` runs `PostgresSession(config:hostKeyValidator:).probe()` with the live
  /// tunnel factory, which no spy can see; this is the same call with the spy injected.
  @Test("The probe leaves no tunnel open", .timeLimit(.minutes(1)))
  func probeLeavesNoTunnel() async throws {
    let harness = Harness()
    _ = harness.makeManager()  // saves the SSH credential
    for _ in 1...2 {
      let session = PostgresSession(
        config: harness.config, tunnelFactory: harness.spy, hostKeyValidator: harness.policy)
      #expect(try await session.probe())
    }
    #expect(harness.spy.tunnels.count == 2)
    #expect(harness.spy.tunnels.allSatisfy { $0.isTornDown })
    harness.expectPinnedOnce()
    harness.store.remove(host: Self.bastionHost, port: Self.bastionPort)
  }
}

private final class FingerprintBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?

  var value: String? { lock.withLock { stored } }
  func set(_ value: String) { lock.withLock { stored = value } }
}

private struct TimeoutError: Error {}

/// Fails instead of hanging xcodebuild when a handshake never completes. NIO futures ignore
/// task cancellation, so this returns on timeout without waiting for `body` to finish.
private func withTimeout<T: Sendable>(
  seconds: Double = 15, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  let gate = ResumeOnce<T>()
  return try await withCheckedThrowingContinuation { continuation in
    gate.set(continuation)
    Task { gate.resume(with: await Result(catching: body)) }
    Task {
      try? await Task.sleep(for: .seconds(seconds))
      gate.resume(with: .failure(TimeoutError()))
    }
  }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, any Error>?

  func set(_ continuation: CheckedContinuation<T, any Error>) {
    lock.withLock { self.continuation = continuation }
  }

  func resume(with result: Result<T, any Error>) {
    let pending = lock.withLock {
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(with: result)
  }
}

extension Result where Failure == any Error {
  fileprivate init(catching body: () async throws -> Success) async {
    do { self = .success(try await body()) } catch { self = .failure(error) }
  }
}
