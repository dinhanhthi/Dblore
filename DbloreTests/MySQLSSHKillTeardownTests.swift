// MySQLSSHKillTeardownTests.swift
// A KILL QUERY control connection racing the close of a MySQL session over SSH. The tunnel is an
// `EchoSSHTunnel` to the MySQL docker fixture (no bastion), so the session runs through a real
// loopback forwarder. Once stopped, the forwarder's port is free for any local process to bind:
// the kill must never dial it then, so the close waits for a dial already under way.

import Foundation
import Testing

@testable import Dblore

@Suite("MySQL KILL QUERY over SSH vs teardown", .serialized)
struct MySQLSSHKillTeardownTests {
  @Test(
    "Closing the session waits for the kill's dial before it stops the forwarder",
    .requiresMySQL, .timeLimit(.minutes(1)))
  func closeWaitsForKillDial() async throws {
    try await TestMySQLDatabase.primeAuthCache()
    let config = ConnectionConfig(
      databaseType: .mysql, host: TestMySQLDatabase.host, port: TestMySQLDatabase.port,
      database: TestMySQLDatabase.database, username: TestMySQLDatabase.username,
      password: TestMySQLDatabase.password, sslMode: .disable,
      sshTunnel: SSHTunnelConfig(host: "bastion-kill.example", port: 2200, username: "jump"),
      timeoutSeconds: 10)
    let account = try #require(SSHCredentialStoreFactory.account(for: config))
    SSHCredentialStoreFactory.shared.save(.password("jump-pass"), account: account)
    let factory = EchoSSHTunnelFactory(targetPort: TestMySQLDatabase.port)
    let session = MySQLSession(
      config: config, tunnelFactory: factory, hostKeyValidator: AcceptAnySSHHostKey())
    try await session.open()
    let tunnel = try #require(factory.tunnels.first)

    let gate = KillGate()
    session.beforeKillForTesting = { await gate.hold() }
    // The forwarder is stopped before the tunnel closes: by then the kill must be released.
    tunnel.onClose = { gate.isReleased }
    let running = Task { try await session.query("SELECT SLEEP(10)", binds: []) }
    try await Task.sleep(for: .milliseconds(300))
    let cancel = Task { await session.interrupt() }
    await gate.waitUntilHeld()
    let close = Task { await session.close() }
    try await Task.sleep(for: .milliseconds(300))
    gate.release()

    await close.value
    await cancel.value
    _ = await running.result
    #expect(tunnel.connectionClosedFirst == true)
    #expect(tunnel.isClosed)
  }
}

/// Holds the kill until `release()`.
private final class KillGate: @unchecked Sendable {
  private let lock = NSLock()
  private var held = false
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?

  var isReleased: Bool { lock.withLock { released } }

  func hold() async {
    await withCheckedContinuation { continuation in
      let now = lock.withLock { () -> Bool in
        held = true
        guard !released else { return true }
        waiter = continuation
        return false
      }
      if now { continuation.resume() }
    }
  }

  func waitUntilHeld() async {
    while !lock.withLock({ held }) { try? await Task.sleep(for: .milliseconds(10)) }
  }

  func release() {
    let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      released = true
      defer { self.waiter = nil }
      return self.waiter
    }
    waiter?.resume()
  }
}
