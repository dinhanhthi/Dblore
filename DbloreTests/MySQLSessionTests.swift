// MySQLSessionTests.swift
// MySQLSession against the docker fixtures (MySQL 8.4 on 3307, MariaDB 11.4 on 3308): connect
// plain / TLS / mTLS, the session pins (sql_mode, utf8mb4, time_zone), the brakes, text and
// prepared statements, zero-row column headers, KILL QUERY cancel and cap, and the error texts.
// Live cases are opt-in (`.requiresMySQL`, `.requiresMySQLTLS`); the transport rule and the
// no-TLS server fixture are not.

import Foundation
import MySQLNIO
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLSessionTests {
  enum Server: String, Sendable, CustomStringConvertible {
    case mysql, mariadb
    var port: Int { self == .mysql ? TestMySQLDatabase.port : TestMySQLDatabase.mariaDBPort }
    var description: String { rawValue }
  }

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - Transport rule (no server)

  @Test("Require, Verify CA and Verify Full refuse a connection that is not encrypted")
  func requireModesRefusePlaintext() throws {
    for mode in SSLMode.allCases {
      if mode.mayBeUnencrypted {
        try MySQLSession.checkTransport(sslMode: mode, isEncrypted: false)
      } else {
        #expect(throws: DatabaseError.self) {
          try MySQLSession.checkTransport(sslMode: mode, isEncrypted: false)
        }
      }
      try MySQLSession.checkTransport(sslMode: mode, isEncrypted: true)
    }
  }

  @Test("Allow, Prefer and Require encrypt without verifying; Verify CA skips only the host name")
  func certificateVerificationPerMode() throws {
    #expect(try MySQLSession.tlsConfiguration(sslMode: .disable, material: nil) == nil)
    for mode in [SSLMode.allow, .prefer, .require] {
      let tls = try #require(try MySQLSession.tlsConfiguration(sslMode: mode, material: nil))
      guard case .none = tls.certificateVerification else {
        Issue.record("\(mode) verifies the certificate")
        continue
      }
    }
    let verifyCA = try #require(
      try MySQLSession.tlsConfiguration(sslMode: .verifyCa, material: nil))
    guard case .noHostnameVerification = verifyCA.certificateVerification else {
      Issue.record("Verify CA: \(verifyCA.certificateVerification)")
      return
    }
    let verifyFull = try #require(
      try MySQLSession.tlsConfiguration(sslMode: .verifyFull, material: nil))
    guard case .fullVerification = verifyFull.certificateVerification else {
      Issue.record("Verify Full: \(verifyFull.certificateVerification)")
      return
    }
  }

  @Test("Only an encrypted Verify CA or Verify Full session counts as verified")
  func transportPerMode() {
    for mode in SSLMode.allCases {
      #expect(MySQLSession.transport(sslMode: mode, isEncrypted: false) == .plaintext)
      let verifies = mode == .verifyCa || mode == .verifyFull
      #expect(
        MySQLSession.transport(sslMode: mode, isEncrypted: true)
          == (verifies ? .verified : .encryptedUnverified), "\(mode)")
    }
  }

  // MARK: - Server without TLS (fixture)

  @Test("Require, Verify CA and Verify Full refuse a server without TLS before the login")
  func requireModesRefuseServerWithoutTLS() async throws {
    let server = try await NoTLSServer.start()
    for mode in [SSLMode.require, .verifyCa, .verifyFull] {
      let session = MySQLSession(config: Self.config(port: server.port, sslMode: mode))
      do {
        try await session.open()
        Issue.record("\(mode) connected to a server without TLS")
      } catch DatabaseError.connectionFailed(let message) {
        #expect(message.contains("does not support TLS"), "\(mode): \(message)")
      }
      await session.close()
    }
    let connections = try await server.closedConnections(3)
    await server.stop()
    #expect(connections.count == 3)
    for bytes in connections { #expect(NoTLSServer.sentNoLogin(bytes), "\(bytes)") }
  }

  @Test("Allow and Prefer retry without TLS when the server has none")
  func preferModesFallBackToPlaintext() async throws {
    let server = try await NoTLSServer.start()
    for mode in [SSLMode.allow, .prefer] {
      let session = MySQLSession(config: Self.config(port: server.port, sslMode: mode))
      // The fixture refuses the login (1045).
      await #expect(throws: DatabaseError.self) { try await session.open() }
      await session.close()
    }
    let connections = try await server.closedConnections(4)
    await server.stop()
    #expect(connections.count == 4)
    let username = Array(TestMySQLDatabase.username.utf8)
    for pair in stride(from: 0, to: connections.count, by: 2) {
      #expect(NoTLSServer.sentNoLogin(connections[pair]))
      #expect(NoTLSServer.contains(connections[pair + 1], username))
    }
  }

  @Test(
    "A proxy strips SSL from the handshake: Prefer runs in plain text, Require sends no login",
    .requiresMySQL, .timeLimit(.minutes(1)))
  func strippedHandshake() async throws {
    let proxy = try await NoTLSServer.start(upstreamPort: TestMySQLDatabase.port)
    try await Self.withSession(Self.config(port: proxy.port, sslMode: .prefer)) { session in
      let cipher = try await Self.rows(session, "SHOW SESSION STATUS LIKE 'Ssl_cipher'")
      #expect(cipher.rows.first?.last == .string(""))
      // KILL QUERY's control connection reuses the plain transport.
      let sleeping = Task { try await Self.rows(session, "SELECT SLEEP(10)") }
      try await Task.sleep(for: .milliseconds(500))
      let start = ContinuousClock.now
      await session.interrupt()
      _ = await sleeping.result
      #expect(ContinuousClock.now - start < .seconds(2))
    }
    let refused = MySQLSession(config: Self.config(port: proxy.port, sslMode: .require))
    await #expect(throws: DatabaseError.self) { try await refused.open() }
    await refused.close()
    let connections = try await proxy.closedConnections(4)
    await proxy.stop()
    #expect(connections.count == 4)
    // Prefer: refused TLS attempt, plain session, plain KILL connection; then Require.
    #expect(NoTLSServer.sentNoLogin(connections[0]))
    #expect(NoTLSServer.sentNoLogin(connections[3]))

    // The real server offers TLS, but not with a CA the system trusts: Verify Full fails the
    // handshake and never retries in plain text.
    let unverified = MySQLSession(
      config: Self.config(port: TestMySQLDatabase.port, sslMode: .verifyFull))
    await #expect(throws: DatabaseError.self) { try await unverified.open() }
    await unverified.close()
  }

  @Test(
    "A proxy strips SSL: Prefer refuses full authentication without asking for the RSA key",
    .requiresMySQL, .timeLimit(.minutes(1)))
  func strippedHandshakeRefusesKeyRetrieval() async throws {
    let user = "session_mitm"
    let password = "mitm-secret-4b7e"
    try await Self.withSession(
      Self.config(port: TestMySQLDatabase.port, username: "root", password: "dblore123")
    ) { root in
      _ = try await root.command("DROP USER IF EXISTS '\(user)'@'%'", binds: [])
      _ = try await root.command(
        "CREATE USER '\(user)'@'%' IDENTIFIED WITH caching_sha2_password BY '\(password)'",
        binds: [])
      do {
        let proxy = try await NoTLSServer.start(upstreamPort: TestMySQLDatabase.port)
        let session = MySQLSession(
          config: Self.config(
            port: proxy.port, username: user, password: password, sslMode: .prefer))
        do {
          try await session.open()
          Issue.record("Prefer logged in through a stripped handshake on a cold cache")
        } catch DatabaseError.connectionFailed(let message) {
          #expect(message.contains(MySQLSession.plaintextFullAuthRefusedMessage), "\(message)")
        }
        await session.close()
        let connections = try await proxy.closedConnections(2)
        await proxy.stop()
        #expect(connections.count == 2)
        // The refused TLS attempt, then the plain one: only the HandshakeResponse41 (scramble,
        // not the password), no request_public_key (0x02), nothing after the server's 0x04.
        #expect(NoTLSServer.sentNoLogin(connections[0]))
        let packets = NoTLSServer.payloads(connections[1])
        #expect(packets.count == 1, "\(packets)")
        #expect(!packets.contains([0x02]))
        #expect(NoTLSServer.contains(connections[1], Array(user.utf8)))
        #expect(!NoTLSServer.contains(connections[1], Array(password.utf8)))
      } catch {
        _ = try? await root.command("DROP USER '\(user)'@'%'", binds: [])
        throw error
      }
      _ = try await root.command("DROP USER '\(user)'@'%'", binds: [])
    }
  }

  // MARK: - Connect

  @Test(
    "Connect over plain TCP, read with and without binds", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func connectAndQuery(server: Server) async throws {
    let session = MySQLSession(config: Self.config(port: server.port))
    try await session.open()
    do {
      let plain = try await Self.rows(session, "SELECT 1 AS one")
      #expect(plain.columns == ["one"])
      #expect(plain.rows == [[.int(1)]])

      let bound = try await Self.rows(
        session, "SELECT ? AS a, ? AS b", binds: [.text("x"), .null])
      #expect(bound.columns == ["a", "b"])
      #expect(bound.rows == [[.string("x"), .null]])
    } catch {
      await session.close()
      throw error
    }
    let events = session.closeEvents
    await session.close()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == .closedByApp)
  }

  @Test("testConnection probes MySQL", .requiresMySQL)
  func testConnectionProbes() async throws {
    let manager = DatabaseConnectionManager()
    #expect(try await manager.testConnection(config: Self.config(port: TestMySQLDatabase.port)))
  }

  @Test(
    "TLS with the fixture CA verifies the server; without it the handshake fails",
    .requiresMySQL, .requiresMySQLTLS)
  func tlsVerifiesTheServer() async throws {
    for mode in [SSLMode.verifyCa, .verifyFull] {
      let config = Self.config(
        port: TestMySQLDatabase.port, sslMode: mode, clientCertificate: true)
      try await Self.withMaterial(for: config) {
        try await Self.withSession(config) { session in
          let cipher = try await Self.rows(session, "SHOW SESSION STATUS LIKE 'Ssl_cipher'")
          #expect(cipher.rows.first?.last != .string(""))
          #expect(cipher.rows.count == 1)
        }
      }
    }
    // No CA: the system roots do not trust the fixture CA. Verify CA and Verify Full never
    // skip verification.
    for mode in [SSLMode.verifyCa, .verifyFull] {
      let unverified = MySQLSession(
        config: Self.config(port: TestMySQLDatabase.port, sslMode: mode))
      await #expect(throws: DatabaseError.self) { try await unverified.open() }
      await unverified.close()
    }
  }

  @Test(
    "A custom CA alone, without a client certificate, verifies the server",
    .requiresMySQL, .requiresMySQLTLS)
  func customCAOnlyVerifiesTheServer() async throws {
    for mode in [SSLMode.verifyCa, .verifyFull] {
      var config = Self.config(port: TestMySQLDatabase.port, sslMode: mode)
      config.clientCertificate = ClientCertificateInfo(subject: nil, expiry: nil, hasCA: true)
      try await Self.withMaterial(for: config, caOnly: true) {
        try await Self.withSession(config) { session in
          let cipher = try await Self.rows(session, "SHOW SESSION STATUS LIKE 'Ssl_cipher'")
          #expect(cipher.rows.first?.last != .string(""))
        }
      }
    }
  }

  @Test(
    "mTLS logs in the REQUIRE X509 user with a client certificate from memory",
    .requiresMySQL, .requiresMySQLTLS)
  func mutualTLS() async throws {
    let config = Self.config(
      port: TestMySQLDatabase.port, username: TestMySQLDatabase.x509Username,
      password: TestMySQLDatabase.x509Password, sslMode: .verifyFull, clientCertificate: true)
    try await Self.withMaterial(for: config) {
      try await Self.withSession(config) { session in
        let user = try await Self.rows(session, "SELECT CURRENT_USER()")
        guard case .string(let name) = user.rows.first?.first else {
          Issue.record("no CURRENT_USER()")
          return
        }
        #expect(name.hasPrefix("dblore_x509@"))
      }
    }
  }

  // MARK: - Session pins and brakes

  @Test(
    "Every session pins sql_mode, utf8mb4 and time_zone, whatever the global sql_mode",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func sessionPins(server: Server) async throws {
    let root = MySQLSession(
      config: Self.config(port: server.port, username: "root", password: "dblore123"))
    try await root.open()
    let original = try await Self.rows(root, "SELECT @@GLOBAL.sql_mode")
    guard case .string(let globalMode) = original.rows.first?.first else {
      await root.close()
      Issue.record("no global sql_mode")
      return
    }
    _ = try await root.command(
      "SET GLOBAL sql_mode = 'ANSI,NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES'", binds: [])
    do {
      try await Self.withSession(Self.config(port: server.port)) { session in
        let values = try await Self.rows(
          session,
          """
          SELECT @@SESSION.sql_mode, @@character_set_client, @@character_set_connection,
            @@character_set_results, @@SESSION.time_zone
          """)
        let row = try #require(values.rows.first)
        guard case .string(let mode) = row[0] else {
          Issue.record("no session sql_mode")
          return
        }
        let flags = mode.split(separator: ",").map(String.init)
        #expect(!flags.contains("ANSI_QUOTES"))
        #expect(!flags.contains("NO_BACKSLASH_ESCAPES"))
        #expect(!flags.contains("ANSI"))
        #expect(flags.contains("STRICT_TRANS_TABLES"))
        #expect(
          Array(row[1...4]) == [
            .string("utf8mb4"), .string("utf8mb4"), .string("utf8mb4"),
            .string("+00:00"),
          ])
      }
    } catch {
      _ = try? await root.command("SET GLOBAL sql_mode = '\(globalMode)'", binds: [])
      await root.close()
      throw error
    }
    _ = try await root.command("SET GLOBAL sql_mode = '\(globalMode)'", binds: [])
    await root.close()
  }

  @Test(
    "Brakes set the statement, lock and idle timeouts", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func brakesApplied(server: Server) async throws {
    try await Self.withSession(Self.config(port: server.port)) { session in
      try await session.applySessionSettings(
        statementTimeoutSeconds: 7, lockTimeoutSeconds: 3, idleTimeoutSeconds: 120)
      let timeout =
        server == .mysql
        ? "@@SESSION.max_execution_time" : "CAST(@@SESSION.max_statement_time AS SIGNED)"
      let values = try await Self.rows(
        session,
        """
        SELECT \(timeout), @@SESSION.innodb_lock_wait_timeout, @@SESSION.lock_wait_timeout,
          @@SESSION.wait_timeout
        """)
      let expected: CellValue = server == .mysql ? .int(7000) : .int(7)
      #expect(values.rows == [[expected, .int(3), .int(3), .int(120)]])
    }
  }

  // MARK: - Statements

  @Test(
    "Zero-row results keep their column headers, also with binds and wide collations",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func zeroRowHeaders(server: Server) async throws {
    try await Self.withSession(Self.config(port: server.port)) { session in
      let collation = server == .mysql ? "utf8mb4_ja_0900_as_cs" : "utf8mb4_uca1400_ai_ci"
      _ = try await session.command("DROP TABLE IF EXISTS session_cols", binds: [])
      _ = try await session.command(
        "CREATE TABLE session_cols (id INT PRIMARY KEY, v VARCHAR(10) COLLATE \(collation))",
        binds: [])
      let insert = try await session.command(
        "INSERT INTO session_cols VALUES (?, ?), (?, ?)",
        binds: [.text("1"), .text("a"), .text("2"), .text("b")])
      #expect(insert.affectedRows == 2)
      #expect(insert.tag.hasPrefix("INSERT"))

      let text = try await Self.rows(session, "SELECT id, v FROM session_cols WHERE 1 = 0")
      #expect(text.columns == ["id", "v"])
      #expect(text.rows.isEmpty)
      let bound = try await Self.rows(
        session, "SELECT id, v FROM session_cols WHERE id = ?", binds: [.text("9")])
      #expect(bound.columns == ["id", "v"])
      #expect(bound.rows.isEmpty)
      let all = try await Self.rows(session, "SELECT v FROM session_cols ORDER BY id")
      #expect(all.rows == [[.string("a")], [.string("b")]])
      _ = try await session.command("DROP TABLE session_cols", binds: [])
    }
  }

  @Test(
    "CALL of a procedure that returns a result set fails with a clear error",
    .requiresMySQL)
  func callWithResultSet() async throws {
    try await Self.withSession(Self.config(port: TestMySQLDatabase.port)) { session in
      _ = try await session.command("DROP PROCEDURE IF EXISTS session_proc", binds: [])
      _ = try await session.command(
        "CREATE PROCEDURE session_proc() BEGIN SELECT 1 AS one; END", binds: [])
      do {
        _ = try await Self.rows(session, "CALL session_proc()")
        Issue.record("CALL returned rows")
      } catch {
        let text = session.formatError(error)
        #expect(text.contains("1312"))
        #expect(text.contains("result set"))
      }
      #expect(try await Self.rows(session, "SELECT 1").rows == [[.int(1)]])
      _ = try await session.command("DROP PROCEDURE session_proc", binds: [])
    }
  }

  // MARK: - KILL QUERY

  @Test(
    "Interrupt stops SLEEP(10) quickly; the session and its transaction survive",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func interruptKeepsSession(server: Server) async throws {
    try await Self.withSession(Self.config(port: server.port)) { session in
      _ = try await session.command("DROP TABLE IF EXISTS session_kill", binds: [])
      _ = try await session.command("CREATE TABLE session_kill (id INT PRIMARY KEY)", binds: [])
      _ = try await session.command("START TRANSACTION", binds: [])
      _ = try await session.command("INSERT INTO session_kill VALUES (1)", binds: [])

      let sleeping = Task { try await Self.rows(session, "SELECT SLEEP(10)") }
      try await Task.sleep(for: .milliseconds(500))
      let start = ContinuousClock.now
      await session.interrupt()
      let result = await sleeping.result
      #expect(ContinuousClock.now - start < .seconds(2))
      if case .success = result { Issue.record("an interrupted SLEEP returned rows") }

      #expect(try await Self.rows(session, "SELECT COUNT(*) FROM session_kill").rows == [[.int(1)]])
      _ = try await session.command("ROLLBACK", binds: [])
      #expect(try await Self.rows(session, "SELECT COUNT(*) FROM session_kill").rows == [[.int(0)]])
      _ = try await session.command("DROP TABLE session_kill", binds: [])
    }
  }

  @Test(
    "Leaving a long read at the cap kills it; the next statement runs at once",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func cappedReadKillsTheRest(server: Server) async throws {
    try await Self.withSession(Self.config(port: server.port)) { session in
      _ = try await session.command(
        server == .mysql
          ? "SET SESSION cte_max_recursion_depth = 2000000"
          : "SET SESSION max_recursive_iterations = 2000000", binds: [])
      let start = ContinuousClock.now
      // Released when this returns, like the connection actor's capped read.
      let seen = try await Self.readFirst(
        10, session,
        """
        WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000000)
        SELECT n FROM seq
        """)
      #expect(seen == 10)
      #expect(try await Self.rows(session, "SELECT 1").rows == [[.int(1)]])
      #expect(ContinuousClock.now - start < .seconds(5))
    }
  }

  @Test(
    "A cancel's late KILL never stops the statement after the cancelled one",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func lateKillSparesNextStatement(server: Server) async throws {
    try await Self.withSession(Self.config(port: server.port)) { session in
      // The KILL connection opens only after the cancelled statement ended on its own.
      session.beforeKillForTesting = { try? await Task.sleep(for: .milliseconds(400)) }
      let first = Task { try await Self.rows(session, "SELECT SLEEP(0.2)") }
      try await Task.sleep(for: .milliseconds(50))
      let cancel = Task { await session.interrupt() }
      _ = await first.result
      // A killed SLEEP returns 1 on MySQL and fails with 1317 on MariaDB.
      #expect(try await Self.rows(session, "SELECT SLEEP(1), 1").rows == [[.int(0), .int(1)]])
      await cancel.value
    }
  }

  @Test(
    "A late KILL never stops a statement already queued behind the cancelled one",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func lateKillSparesQueuedStatement(server: Server) async throws {
    try await Self.withSession(Self.config(port: server.port)) { session in
      // The KILL connection opens after the cancelled statement ended on its own and the
      // queued ones could have been sent. The cancel also fails the first waiting statement;
      // the one behind it is not cancelled and must not be killed.
      session.beforeKillForTesting = { try? await Task.sleep(for: .milliseconds(400)) }
      let first = Task { try await Self.rows(session, "SELECT SLEEP(0.3)") }
      try await Task.sleep(for: .milliseconds(50))
      let cancelled = Task { try await Self.rows(session, "SELECT 2") }
      try await Task.sleep(for: .milliseconds(20))
      let queued = Task { try await Self.rows(session, "SELECT SLEEP(1), 1") }
      try await Task.sleep(for: .milliseconds(50))
      await session.interrupt()
      _ = await first.result
      await #expect(throws: MySQLSessionError.interrupted) { _ = try await cancelled.value }
      // A killed SLEEP returns 1 on MySQL and fails with 1317 on MariaDB.
      #expect(try await queued.value.rows == [[.int(0), .int(1)]])
    }
  }

  @Test(
    "A cancel fails the statement waiting behind the running one before it is sent",
    .requiresMySQL, .timeLimit(.minutes(1)))
  func cancelFailsWaitingStatement() async throws {
    let proxy = try await NoTLSServer.start(upstreamPort: TestMySQLDatabase.port)
    let marker = "queued_marker_7f3a"
    try await Self.withSession(Self.config(port: proxy.port)) { session in
      let running = Task { try await Self.rows(session, "SELECT SLEEP(10)") }
      try await Task.sleep(for: .milliseconds(300))
      let waiting = Task { try await Self.rows(session, "SELECT '\(marker)'") }
      try await Task.sleep(for: .milliseconds(50))
      let start = ContinuousClock.now
      await session.interrupt()
      await #expect(throws: MySQLSessionError.interrupted) { _ = try await running.value }
      await #expect(throws: MySQLSessionError.interrupted) { _ = try await waiting.value }
      #expect(ContinuousClock.now - start < .seconds(2))
      // The session still runs the next statement.
      #expect(try await Self.rows(session, "SELECT 1").rows == [[.int(1)]])
    }
    let connections = try await proxy.closedConnections(2)
    await proxy.stop()
    #expect(connections.count == 2)
    for bytes in connections { #expect(!NoTLSServer.contains(bytes, Array(marker.utf8))) }
  }

  @Test(
    "Repeated cancels of one statement open one KILL connection", .requiresMySQL,
    .timeLimit(.minutes(1)))
  func repeatedCancelsCoalesce() async throws {
    let proxy = try await NoTLSServer.start(upstreamPort: TestMySQLDatabase.port)
    try await Self.withSession(Self.config(port: proxy.port)) { session in
      session.beforeKillForTesting = { try? await Task.sleep(for: .milliseconds(300)) }
      let sleeping = Task { try await Self.rows(session, "SELECT SLEEP(10)") }
      try await Task.sleep(for: .milliseconds(300))
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<3 { group.addTask { await session.interrupt() } }
      }
      _ = await sleeping.result
    }
    _ = try await proxy.closedConnections(2)
    await proxy.stop()
    // The session and one KILL connection.
    #expect(proxy.openedConnections == 2)
  }

  // MARK: - Full-authentication guard (no server)

  /// What the armed guard refuses after the greeting, and the text the user reads for it.
  nonisolated static let guardRefusals: [([UInt8], FullAuthRefusal.Reason, String)] = [
    (
      MySQLWireFixtures.performFullAuthentication, .fullAuthentication,
      MySQLSession.fullAuthRefusedMessage
    ),
    (
      // Worded as when the fork itself refuses a plugin it cannot use.
      MySQLWireFixtures.authSwitchRequest(plugin: "sha256_password"),
      .authSwitch(plugin: "sha256_password"),
      MySQLSessionError(MySQLError.unsupportedAuthPlugin(name: "sha256_password")).message
    ),
    (
      MySQLWireFixtures.authSwitchRequest(plugin: "client_ed25519"),
      .authSwitch(plugin: "client_ed25519"),
      MySQLSession.unsupportedAuthPluginMessage("client_ed25519")
    ),
    // A hostile server's name (line breaks with fake guidance, a bidi override, a long string)
    // never reaches the user's text, and the guard keeps at most 65 bytes of it.
    (
      MySQLWireFixtures.authSwitchRequest(plugin: "x\nCall +1 555 0100 for help"),
      .authSwitch(plugin: "x\nCall +1 555 0100 for help"),
      MySQLSession.unsupportedSignInMessage
    ),
    (
      MySQLWireFixtures.authSwitchRequest(plugin: "x\u{202E}drowssap"),
      .authSwitch(plugin: "x\u{202E}drowssap"), MySQLSession.unsupportedSignInMessage
    ),
    (
      MySQLWireFixtures.authSwitchRequest(plugin: String(repeating: "a", count: 200)),
      .authSwitch(plugin: String(repeating: "a", count: 65)), MySQLSession.unsupportedSignInMessage
    ),
  ]

  @Test(
    "mysql-nio's unsupported plugin shows its name only when it is a plain identifier",
    arguments: [("client_ed25519", true), ("x\nCall +1 555 0100 for help", false)])
  func forkUnsupportedPluginMessage(name: String, shown: Bool) {
    let message = MySQLSessionError(MySQLError.unsupportedAuthPlugin(name: name)).message
    if shown {
      #expect(message.contains(name))
    } else {
      #expect(message == MySQLSession.unsupportedSignInMessage)
    }
  }

  @Test(
    "A login the armed guard refuses fails with the guard's reason, not 'closed'",
    arguments: guardRefusals)
  func guardRefusalMessage(
    payload: [UInt8], reason: FullAuthRefusal.Reason, message: String
  ) throws {
    let config = Self.config(host: "db.example", port: 3306, sslMode: .prefer)
    let login = try GuardedLogin(config: config)
    try login.channel.writeInbound(Self.wire(0, MySQLWireFixtures.greeting(ssl: false)))
    _ = try MySQLFullAuthGuardTests.outbound(login.channel)
    try login.channel.writeInbound(Self.wire(2, payload))

    #expect(login.refusal.reason == reason)
    #expect((login.captured.error as? MySQLSessionError)?.message == message)
    #expect(try MySQLFullAuthGuardTests.outbound(login.channel).isEmpty)
  }

  @Test("A direct loopback login is not guarded and never asks for the server's RSA key")
  func loopbackRefusesFullAuthWithoutKeyRetrieval() throws {
    let config = Self.config(host: "127.0.0.1", port: 3306, sslMode: .prefer)
    let login = try GuardedLogin(config: config)
    try login.channel.writeInbound(Self.wire(0, MySQLWireFixtures.greeting(ssl: false)))
    _ = try MySQLFullAuthGuardTests.outbound(login.channel)
    try login.channel.writeInbound(Self.wire(2, MySQLWireFixtures.performFullAuthentication))

    // With allowPublicKeyRetrieval the fork would send request_public_key (0x02) and wait.
    #expect(MySQLFullAuthGuardTests.isPublicKeyRetrievalNotAllowed(login.captured.error))
    #expect(!login.refusal.refused)
    let error = try #require(login.captured.error)
    #expect(MySQLSessionError(error).message == MySQLSession.plaintextFullAuthRefusedMessage)
  }

  @Test("A successful login disarms the guard before the first result reaches the fork")
  func loginDisarmsTheGuard() throws {
    let config = Self.config(host: "db.example", port: 3306, sslMode: .prefer)
    let login = try GuardedLogin(config: config)
    try login.channel.writeInbound(Self.wire(0, MySQLWireFixtures.greeting(ssl: false)))
    _ = try MySQLFullAuthGuardTests.outbound(login.channel)
    try login.channel.writeInbound(
      ByteBuffer(
        bytes: MySQLWireFixtures.frame(sequence: 2, MySQLWireFixtures.fastAuthSuccess)
          + MySQLWireFixtures.frame(sequence: 3, MySQLWireFixtures.ok)))
    #expect(try login.captured.result?.get() != nil)

    // A one-column result's column count: an armed guard refuses it as AuthMoreData.
    let columnCount = MySQLWireFixtures.frame(sequence: 1, [0x01])
    try login.channel.writeInbound(ByteBuffer(bytes: columnCount))
    #expect(login.spy.seen.last == columnCount)
    #expect(!login.refusal.refused)
  }

  /// `MySQLSession.login(over:)` on an EmbeddedChannel holding the guard the session's
  /// bootstrap adds for `config`, and a spy after it.
  @MainActor struct GuardedLogin {
    let channel: EmbeddedChannel
    let spy: MySQLFullAuthGuardTests.InboundSpy
    let refusal = FullAuthRefusal()
    let captured: MySQLFullAuthGuardTests.Captured<MySQLConnection>

    init(config: ConnectionConfig) throws {
      let armed = armsFullAuthGuard(
        tlsMode: config.sslMode, host: config.host, usesSSH: config.sshTunnel != nil)
      (channel, spy) = try MySQLFullAuthGuardTests.channel(
        guard: MySQLFullAuthGuard(armed: armed, refusal: refusal))
      captured = MySQLFullAuthGuardTests.Captured(
        MySQLSession.login(over: channel, config: config, tls: nil, refusal: refusal))
    }
  }

  static func wire(_ sequence: UInt8, _ payload: [UInt8]) -> ByteBuffer {
    ByteBuffer(bytes: MySQLWireFixtures.frame(sequence: sequence, payload))
  }

  // MARK: - Packets (no server)

  @Test("A binary value length above Int.max is a protocol error")
  func binaryRowLengthOverflow() throws {
    var packet = Self.packet([0x00, 0x00, 0xFE] + Array(repeating: 0xFF, count: 8))
    let columns = [try Self.columnDefinition(.varString)]
    #expect(throws: MySQLError.self) {
      _ = try MySQLStatementPackets.binaryRow(&packet, columns: columns)
    }
  }

  /// Length-encoded column counts: above Int.max, 0 (as 0xFC 0 0, not the OK byte), 4097.
  static let hostileColumnCounts: [[UInt8]] = [
    [0xFE] + Array(repeating: 0xFF, count: 8), [0xFC, 0x00, 0x00], [0xFC, 0x01, 0x10],
  ]

  @Test("A prepared column count of 0 or above 4096 is a protocol error")
  func preparedColumnCountOverflow() throws {
    for bytes in Self.hostileColumnCounts {
      let query = MySQLPreparedQuery(sql: "DO 0", binds: [], callbacks: Self.callbacks(Rows()))
      var prepareOK = Self.packet([0x00, 1, 0, 0, 0, 0, 0, 0, 0, 0x00, 0, 0])
      _ = try query.handle(packet: &prepareOK, capabilities: .clientDefault)
      var count = Self.packet(bytes)
      #expect(throws: MySQLError.self, "\(bytes)") {
        _ = try query.handle(packet: &count, capabilities: .clientDefault)
      }
    }
  }

  @Test("A text column count of 0 or above 4096 is a protocol error")
  func textColumnCountOverflow() {
    for bytes in Self.hostileColumnCounts {
      let query = MySQLTextQuery(sql: "DO 0", callbacks: Self.callbacks(Rows()))
      var count = Self.packet(bytes)
      #expect(throws: MySQLError.self, "\(bytes)") {
        _ = try query.handle(packet: &count, capabilities: .clientDefault)
      }
    }
  }

  @Test("A full-size text row starting 0xFE is a row; a 0xFE OK packet ends the result")
  func textRowStartingFE() throws {
    let rows = Rows()
    let query = MySQLTextQuery(sql: "SELECT c", callbacks: Self.callbacks(rows))
    var count = Self.packet([0x01])
    _ = try query.handle(packet: &count, capabilities: .clientDefault)
    var column = Self.columnDefinitionPacket(.varString)
    _ = try query.handle(packet: &column, capabilities: .clientDefault)
    // A first value of 16 MiB or more: length-encoded with 0xFE, in a 0xFFFFFF-byte packet.
    let valueLength = 0xFF_FFFF - 9
    var payload = ByteBufferAllocator().buffer(capacity: 0xFF_FFFF)
    payload.writeInteger(UInt8(0xFE))
    payload.writeInteger(UInt64(valueLength), endianness: .little)
    payload.writeRepeatingByte(0x61, count: valueLength)
    var row = MySQLPacket(payload: payload)
    _ = try query.handle(packet: &row, capabilities: .clientDefault)
    #expect(rows.count == 1)
    // CLIENT_DEPRECATE_EOF's closing OK, with an info string.
    var ok = Self.packet([0xFE, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00] + Array("info".utf8))
    _ = try query.handle(packet: &ok, capabilities: .clientDefault)
    #expect(rows.count == 1)
  }

  // MARK: - Error texts

  @Test(
    "A 32-character caching_sha2 password: refused over plain TCP until a TLS login caches it",
    .requiresMySQL)
  func longPasswordOverPlainTCP() async throws {
    let password = "abcdefghijklmnopqrstuvwxyz012345"
    try await Self.withSession(
      Self.config(port: TestMySQLDatabase.port, username: "root", password: "dblore123")
    ) { root in
      _ = try await root.command("DROP USER IF EXISTS 'session_long'@'%'", binds: [])
      _ = try await root.command(
        "CREATE USER 'session_long'@'%' IDENTIFIED WITH caching_sha2_password BY '\(password)'",
        binds: [])
      _ = try await root.command(
        "GRANT SELECT ON \(TestMySQLDatabase.database).* TO 'session_long'@'%'", binds: [])
      do {
        // Cold cache: full authentication would need the RSA key over plain TCP. Refused.
        let cold = MySQLSession(
          config: Self.config(
            port: TestMySQLDatabase.port, username: "session_long", password: password))
        do {
          try await cold.open()
          Issue.record("plain TCP full authentication succeeded")
        } catch DatabaseError.connectionFailed(let message) {
          #expect(message.contains(MySQLSession.plaintextFullAuthRefusedMessage), "\(message)")
        }
        await cold.close()
        // A TLS login fills the cache; plain TCP then uses fast authentication (20-byte scramble).
        try await TestMySQLDatabase.primeAuthCache(username: "session_long", password: password)
        for _ in 0..<2 {
          try await Self.withSession(
            Self.config(
              port: TestMySQLDatabase.port, username: "session_long", password: password)
          ) { session in
            let user = try await Self.rows(session, "SELECT CURRENT_USER()")
            guard case .string(let name) = user.rows.first?.first else {
              Issue.record("no CURRENT_USER()")
              return
            }
            #expect(name.hasPrefix("session_long@"))
          }
        }
      } catch {
        _ = try? await root.command("DROP USER 'session_long'@'%'", binds: [])
        throw error
      }
      _ = try await root.command("DROP USER 'session_long'@'%'", binds: [])
    }
  }

  // MARK: - Helpers

  static func config(
    host: String = TestMySQLDatabase.host, port: Int, username: String = TestMySQLDatabase.username,
    password: String = TestMySQLDatabase.password, sslMode: SSLMode = .disable,
    clientCertificate: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .mysql, host: host, port: port,
      database: TestMySQLDatabase.database, username: username, password: password,
      sslMode: sslMode,
      clientCertificate: clientCertificate
        ? ClientCertificateInfo(subject: "dblore test client", expiry: nil, hasCA: true) : nil,
      rememberConnection: false, timeoutSeconds: 10)
  }

  /// Runs `body` with the fixture client certificate and CA scoped to `config`'s account
  /// (`caOnly`: the CA without a client certificate).
  static func withMaterial(
    for config: ConnectionConfig, caOnly: Bool = false, _ body: () async throws -> Void
  ) async throws {
    let caPEM = try String(contentsOf: TestMySQLDatabase.caCertificate, encoding: .utf8)
    let material =
      caOnly
      ? ClientCertificateMaterial(caPEM: caPEM)
      : ClientCertificateMaterial(
        certificatePEM: try String(
          contentsOf: TestMySQLDatabase.clientCertificate, encoding: .utf8),
        privateKeyPEM: try String(contentsOf: TestMySQLDatabase.clientKey, encoding: .utf8),
        caPEM: caPEM)
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: config), material: material)
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await body()
    }
  }

  /// Opens a session and closes it on every path.
  static func withSession(
    _ config: ConnectionConfig, _ body: (MySQLSession) async throws -> Void
  ) async throws {
    let session = MySQLSession(config: config)
    do {
      try await session.open()
      try await body(session)
    } catch {
      await session.close()
      throw error
    }
    await session.close()
  }

  /// Reads `count` rows of `sql`, then leaves the rest.
  static func readFirst(_ count: Int, _ session: MySQLSession, _ sql: String) async throws -> Int {
    let source = try await session.query(sql, binds: [])
    var seen = 0
    for try await _ in source.rows {
      seen += 1
      if seen == count { break }
    }
    return seen
  }

  /// Counts the rows a command reports.
  final class Rows: @unchecked Sendable {
    var count = 0
  }

  static func callbacks(_ rows: Rows) -> MySQLStatementCallbacks {
    MySQLStatementCallbacks(columns: { _ in }, row: { _ in rows.count += 1 }, ok: { _ in })
  }

  static func packet(_ bytes: [UInt8]) -> MySQLPacket {
    var payload = ByteBufferAllocator().buffer(capacity: bytes.count)
    payload.writeBytes(bytes)
    return MySQLPacket(payload: payload)
  }

  /// A ColumnDefinition41 packet for column `c` of `type`, utf8mb4.
  static func columnDefinitionPacket(_ type: MySQLProtocol.DataType) -> MySQLPacket {
    var bytes: [UInt8] = [0, 0, 0, 0, 1, 0x63, 0, 0x0C, 0x2D, 0x00, 0xFF, 0, 0, 0]
    bytes += [type.rawValue, 0, 0, 0, 0, 0]
    return packet(bytes)
  }

  static func columnDefinition(
    _ type: MySQLProtocol.DataType
  ) throws -> MySQLProtocol.ColumnDefinition41 {
    var packet = columnDefinitionPacket(type)
    return try .decode(from: &packet, capabilities: .clientDefault)
  }

  static func rows(
    _ session: MySQLSession, _ sql: String, binds: [SQLBindValue] = []
  ) async throws -> (columns: [String], rows: [[CellValue]]) {
    let source = try await session.query(sql, binds: binds)
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return (source.columns.map(\.name), rows)
  }
}

/// A loopback MySQL endpoint without TLS. Alone it sends a HandshakeV10 without CLIENT_SSL and
/// refuses the login with ERROR 1045, or answers it once with `loginReply` and leaves the close
/// to the client; with `upstreamPort` it proxies a real server
/// and clears CLIENT_SSL in the server's handshake (a downgrade by a man in the middle). It
/// records the bytes each client connection sent.
nonisolated final class NoTLSServer: @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [[UInt8]] = []
  private var closed: Set<Int> = []
  private var channel: (any Channel)?
  private let upstreamPort: Int?
  private let loginReply: [UInt8]?

  private init(upstreamPort: Int?, loginReply: [UInt8]?) {
    self.upstreamPort = upstreamPort
    self.loginReply = loginReply
  }

  var port: Int { channel?.localAddress?.port ?? 0 }

  static func start(
    upstreamPort: Int? = nil, loginReply: [UInt8]? = nil
  ) async throws -> NoTLSServer {
    let server = NoTLSServer(upstreamPort: upstreamPort, loginReply: loginReply)
    server.channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { child in
        child.eventLoop.makeCompletedFuture {
          try child.pipeline.syncOperations.addHandler(ClientSide(server: server))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
    return server
  }

  func stop() async { try? await channel?.close().get() }

  /// Client connections accepted so far.
  var openedConnections: Int { lock.withLock { sent.count } }

  /// The bytes of the first `count` connections, once all of them have closed.
  func closedConnections(_ count: Int) async throws -> [[UInt8]] {
    for _ in 0..<500 {
      let done = lock.withLock { (0..<count).allSatisfy(closed.contains) }
      if done { return lock.withLock { Array(sent.prefix(count)) } }
      try await Task.sleep(for: .milliseconds(10))
    }
    return lock.withLock { Array(sent.prefix(count)) }
  }

  /// Nothing, or only COM_QUIT (mysql-nio's close): no SSLRequest, no HandshakeResponse41.
  static func sentNoLogin(_ bytes: [UInt8]) -> Bool {
    bytes.isEmpty || (bytes.count == 5 && bytes[4] == 0x01)
  }

  /// The payloads of the MySQL packets in `bytes` (3-byte length, sequence id, payload).
  static func payloads(_ bytes: [UInt8]) -> [[UInt8]] {
    var packets: [[UInt8]] = []
    var index = 0
    while index + 4 <= bytes.count {
      let length = Int(bytes[index]) | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]) << 16
      let end = min(index + 4 + length, bytes.count)
      packets.append(Array(bytes[(index + 4)..<end]))
      index = end
    }
    return packets
  }

  static func contains(_ bytes: [UInt8], _ part: [UInt8]) -> Bool {
    bytes.count >= part.count
      && (0...(bytes.count - part.count)).contains { Array(bytes[$0..<$0 + part.count]) == part }
  }

  /// A MySQL 8 HandshakeV10 (protocol 41, secure connection, plugin auth) without CLIENT_SSL.
  static let handshake: [UInt8] = {
    var payload: [UInt8] = [0x0A] + Array("8.4.0-fixture".utf8) + [0, 1, 0, 0, 0]
    payload += Array("abcdefgh".utf8) + [0]
    payload += [0x0D, 0xA2, 0xFF, 0x02, 0x00, 0x08, 0x00, 21] + Array(repeating: 0, count: 10)
    payload += Array("ijklmnopqrst".utf8) + [0] + Array("caching_sha2_password".utf8) + [0]
    let count = payload.count
    return [UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), 0, 0] + payload
  }()

  /// ERROR 1045 (28000), sequence 2: the answer to a HandshakeResponse41.
  static let accessDenied: [UInt8] = {
    let payload: [UInt8] =
      [0xFF, 0x15, 0x04] + Array("#28000".utf8) + Array("Access denied (fixture)".utf8)
    return [UInt8(payload.count), 0, 0, 2] + payload
  }()

  /// Clears CLIENT_SSL (0x0800) in a complete HandshakeV10 packet.
  static func stripSSL(_ packet: inout [UInt8]) {
    guard let end = packet[5...].firstIndex(of: 0) else { return }
    let capabilities = end + 1 + 4 + 8 + 1
    if capabilities + 1 < packet.count { packet[capabilities + 1] &= ~0x08 }
  }

  private func open() -> Int {
    lock.withLock {
      sent.append([])
      return sent.count - 1
    }
  }

  private func record(_ bytes: [UInt8], _ index: Int) { lock.withLock { sent[index] += bytes } }
  private func close(_ index: Int) { _ = lock.withLock { closed.insert(index) } }

  private final class ClientSide: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let server: NoTLSServer
    var index = 0
    var upstream: (any Channel)?
    var replied = false

    init(server: NoTLSServer) { self.server = server }

    func channelActive(context: ChannelHandlerContext) {
      index = server.open()
      let client = context.channel
      guard let port = server.upstreamPort else {
        client.writeAndFlush(ByteBuffer(bytes: NoTLSServer.handshake), promise: nil)
        return
      }
      ClientBootstrap(group: context.eventLoop)
        .channelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ServerSide(client: client))
          }
        }
        .connect(host: "127.0.0.1", port: port)
        .whenComplete { [self] result in
          switch result {
          case .success(let channel): upstream = channel
          case .failure: client.close(promise: nil)
          }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      let bytes = Array(buffer: unwrapInboundIn(data))
      server.record(bytes, index)
      if let upstream {
        upstream.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
      } else if let reply = server.loginReply, !NoTLSServer.sentNoLogin(bytes) {
        // Once, to the login; the connection stays open to record what the client sends next.
        guard !replied else { return }
        replied = true
        context.channel.writeAndFlush(ByteBuffer(bytes: reply), promise: nil)
      } else if server.upstreamPort == nil {
        // mysql-nio waits for an answer to its login: refuse it rather than just closing.
        let reply = NoTLSServer.sentNoLogin(bytes) ? [] : NoTLSServer.accessDenied
        let channel = context.channel
        channel.writeAndFlush(ByteBuffer(bytes: reply)).whenComplete { _ in
          channel.close(promise: nil)
        }
      }
    }

    func channelInactive(context: ChannelHandlerContext) {
      upstream?.close(promise: nil)
      server.close(index)
    }
  }

  private final class ServerSide: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let client: any Channel
    /// The server's handshake until it is complete; nil once forwarded.
    var handshake: [UInt8]? = []

    init(client: any Channel) { self.client = client }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      var bytes = Array(buffer: unwrapInboundIn(data))
      if var pending = handshake {
        pending += bytes
        let length = pending.count >= 4 ? Int(pending[0]) | Int(pending[1]) << 8 : Int.max
        guard pending.count >= 4 + length else {
          handshake = pending
          return
        }
        NoTLSServer.stripSSL(&pending)
        handshake = nil
        bytes = pending
      }
      client.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) { client.close(promise: nil) }
  }
}
