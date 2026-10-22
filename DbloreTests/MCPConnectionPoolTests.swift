// MCPConnectionPoolTests.swift
// The MCP pool: one read-only manager per saved connection, reused while in use, refused
// without a prompt when a secret or trust decision is missing, closed when idle.

import Foundation
import Testing

@testable import Dblore

/// Saved connections by id, editable by a test.
@MainActor
private final class EntryBook {
  private var entries: [UUID: ConnectionHistoryEntry] = [:]

  @discardableResult
  func add(_ config: ConnectionConfig) -> UUID {
    var entry = ConnectionHistoryEntry(config: config)
    entry.config.password = config.password
    entries[entry.id] = entry
    return entry.id
  }

  func update(_ id: UUID, _ change: (inout ConnectionConfig) -> Void) {
    guard var entry = entries[id] else { return }
    change(&entry.config)
    entries[id] = entry
  }

  func entry(_ id: UUID) -> ConnectionHistoryEntry? {
    entries[id]
  }
}

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = ContinuousClock.now

  var now: ContinuousClock.Instant { lock.withLock { current } }

  func advance(by duration: Duration) {
    lock.withLock { current = current.advanced(by: duration) }
  }
}

@MainActor
@Suite("MCP connection pool")
struct MCPConnectionPoolTests {
  private let book = EntryBook()
  private let clock = ManualClock()
  private let factory = FakeDatabaseSessionFactory(capabilities: .contract())
  private let certificates = InMemoryClientCertificateStore()
  private let sshCredentials = InMemorySSHCredentialStore()
  private let knownHosts = InMemorySSHKnownHostStore()

  private func pool() -> MCPConnectionPool {
    let book = book
    let clock = clock
    return MCPConnectionPool(
      entry: { await book.entry($0) }, sessionFactory: factory, certificates: certificates,
      sshCredentials: sshCredentials, knownHosts: knownHosts, now: { clock.now })
  }

  private func postgres(
    password: String = "secret", database: String = "db"
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: database, username: "u",
      password: password, sslMode: .disable, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
  }

  private func manager(
    _ pool: MCPConnectionPool, _ id: UUID
  ) async throws -> DatabaseConnectionManager {
    try await pool.withManager(for: id) { $0 }
  }

  @Test("One manager per connection, shared by concurrent and later callers")
  func reusesManager() async throws {
    let pool = pool()
    let id = book.add(postgres())
    async let first = manager(pool, id)
    async let second = manager(pool, id)
    let (a, b) = try await (first, second)
    let c = try await manager(pool, id)
    #expect(a === b)
    #expect(a === c)
    #expect(factory.sessions.count == 1)
    await pool.closeAll()
  }

  @Test("An edited connection reconnects with its new settings")
  func editedConnectionReconnects() async throws {
    let pool = pool()
    let id = book.add(postgres())
    let before = try await manager(pool, id)
    book.update(id) { $0.database = "renamed" }
    let after = try await manager(pool, id)
    #expect(before !== after)
    #expect(await !before.isConnected)
    #expect(await after.config?.database == "renamed")
    await pool.closeAll()
  }

  @Test("close(id:) disconnects that connection's manager only; a later caller reconnects")
  func closeOne() async throws {
    let pool = pool()
    let id = book.add(postgres(database: "one"))
    let other = try await manager(pool, book.add(postgres(database: "two")))
    let before = try await manager(pool, id)
    await pool.close(id: id)
    #expect(await !before.isConnected)
    #expect(await other.isConnected)
    let after = try await manager(pool, id)
    #expect(after !== before)
    #expect(await after.isConnected)
    await pool.closeAll()
  }

  @Test(
    "A connection edited while a read runs: new callers get a new manager, the old one closes after"
  )
  func editedWhileInUse() async throws {
    let pool = pool()
    let id = book.add(postgres())
    let book = book
    let (old, new, oldOpenInside) = try await pool.withManager(for: id) { old in
      await MainActor.run { book.update(id) { $0.database = "renamed" } }
      let new = try await pool.withManager(for: id) { $0 }
      return (old, new, await old.isConnected)
    }
    #expect(old !== new)
    #expect(oldOpenInside)
    #expect(await !old.isConnected)
    #expect(await new.config?.database == "renamed")
    #expect(try await manager(pool, id) === new)
    await pool.closeAll()
  }

  @Test("closeAll while a replaced manager is in use closes the old and the new manager")
  func closeAllClosesRetired() async throws {
    let pool = pool()
    let id = book.add(postgres())
    let book = book
    let (old, new) = try await pool.withManager(for: id) { old in
      await MainActor.run { book.update(id) { $0.database = "renamed" } }
      let new = try await pool.withManager(for: id) { $0 }
      await pool.closeAll()
      return (old, new)
    }
    #expect(old !== new)
    #expect(await !old.isConnected)
    #expect(await !new.isConnected)
  }

  @Test("A lost manager still held by a caller is replaced, then closed when that caller ends")
  func lostManagerInUseRetired() async throws {
    let pool = pool()
    let config = postgres()
    let id = book.add(config)
    let (old, new, oldUsable) = try await pool.withManager(for: id) { old in
      await old.markSessionLost(epoch: old.connectionEpoch)
      let new = try await pool.withManager(for: id) { $0 }
      // The outer caller may still reconnect and use its manager
      try await old.connect(config: config)
      return (old, new, await old.isConnected)
    }
    #expect(old !== new)
    #expect(oldUsable)
    #expect(await !old.isConnected)
    #expect(await new.isConnected)
    #expect(try await manager(pool, id) === new)
    await pool.closeAll()
  }

  @Test("A closed pool refuses new callers without connecting")
  func closedPoolRefuses() async throws {
    let pool = pool()
    let id = book.add(postgres())
    _ = try await manager(pool, id)
    await pool.closeAll()
    await #expect(throws: MCPConnectionError.stopped) {
      _ = try await manager(pool, id)
    }
    #expect(factory.sessions.count == 1)
  }

  @Test("A manager that lost its session is replaced by the next caller")
  func lostSessionReplaced() async throws {
    let pool = pool()
    let id = book.add(postgres())
    let first = try await manager(pool, id)
    await first.markSessionLost(epoch: first.connectionEpoch)
    let second = try await manager(pool, id)
    #expect(first !== second)
    #expect(await second.isConnected)
    #expect(factory.sessions.count == 2)
    await pool.closeAll()
  }

  @Test("An unknown connection is refused")
  func unknownConnectionRefused() async throws {
    await #expect(throws: MCPConnectionError.unknownConnection) {
      _ = try await manager(pool(), UUID())
    }
  }

  @Test("A connection with an empty password still connects (trust or passwordless auth)")
  func emptyPasswordConnects() async throws {
    let pool = pool()
    let id = book.add(postgres(password: ""))
    _ = try await manager(pool, id)
    #expect(factory.sessions.count == 1)
    await pool.closeAll()
  }

  @Test("Sessions get the MCP statement timeout; a shorter one of the connection is kept")
  func statementTimeoutCapped() async throws {
    let pool = pool()
    let long = book.add(postgres(database: "long"))
    var short = postgres(database: "short")
    short.statementTimeoutSeconds = 10
    let shortID = book.add(short)
    #expect(try await manager(pool, long).config?.statementTimeoutSeconds == 30)
    #expect(try await manager(pool, shortID).config?.statementTimeoutSeconds == 10)
    #expect(try await manager(pool, long) === manager(pool, long))
    await pool.closeAll()
  }

  @Test("A client certificate that is not in the Keychain is refused before connecting")
  func unrememberedCertificateRefused() async throws {
    var config = postgres()
    config.clientCertificate = ClientCertificateInfo(subject: "CN=u", expiry: nil, hasCA: true)
    let id = book.add(config)
    let pool = pool()
    await #expect(throws: MCPConnectionError.certificateNotSaved) {
      _ = try await manager(pool, id)
    }
    #expect(factory.sessions.isEmpty)

    certificates.save(
      ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key", caPEM: "ca"),
      account: ClientCertificateStoreFactory.account(for: config))
    _ = try await manager(pool, id)
    #expect(factory.sessions.count == 1)
    await pool.closeAll()
  }

  @Test("A connection with a password command is refused: MCP never runs the user's scripts")
  func passwordCommandRefused() async throws {
    var config = postgres()
    config.passwordCommandScript = "pw.sh"
    let id = book.add(config)
    let pool = pool()
    await #expect(throws: MCPConnectionError.passwordCommand) {
      _ = try await manager(pool, id)
    }
    #expect(factory.sessions.isEmpty)
    await pool.closeAll()
  }

  @Test("An SSH bastion without a saved secret or a pinned host key is refused")
  func untrustedSSHRefused() async throws {
    var config = postgres()
    config.sshTunnel = SSHTunnelConfig(host: "bastion", username: "jump")
    let id = book.add(config)
    let pool = pool()
    await #expect(throws: MCPConnectionError.sshCredentialNotSaved) {
      _ = try await manager(pool, id)
    }
    sshCredentials.save(
      .password("ssh-secret"), account: SSHCredentialStoreFactory.account(for: config)!)
    await #expect(throws: MCPConnectionError.sshHostKeyNotTrusted) {
      _ = try await manager(pool, id)
    }
    #expect(factory.sessions.isEmpty)

    _ = try knownHosts.trust(
      host: "bastion", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:abc")
    _ = try await manager(pool, id)
    #expect(factory.sessions.count == 1)
    await pool.closeAll()
  }

  @Test("An idle manager is disconnected after the idle timeout, then rebuilt on demand")
  func idleManagerCloses() async throws {
    let pool = pool()
    let id = book.add(postgres())
    let first = try await manager(pool, id)
    clock.advance(by: .seconds(299))
    await pool.closeIdle()
    #expect(await first.isConnected)

    clock.advance(by: .seconds(1))
    await pool.closeIdle()
    #expect(await !first.isConnected)
    let second = try await manager(pool, id)
    #expect(first !== second)
    #expect(factory.sessions.count == 2)
    await pool.closeAll()
  }

  @Test("A manager in use is never closed as idle")
  func inUseManagerStaysOpen() async throws {
    let pool = pool()
    let id = book.add(postgres())
    let clock = clock
    let used = try await pool.withManager(for: id) { manager in
      clock.advance(by: .seconds(600))
      await pool.closeIdle()
      return manager
    }
    #expect(await used.isConnected)
    await pool.closeAll()
    #expect(await !used.isConnected)
  }
}
