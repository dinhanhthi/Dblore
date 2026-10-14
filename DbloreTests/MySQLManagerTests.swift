// MySQLManagerTests.swift
// MySQL 8.4 (3307, TLS fixtures) and MariaDB 11.4 (3308) through DatabaseConnectionManager:
// connect plain / TLS / mTLS, the brakes, KILL QUERY cancel (session, epoch and app transaction
// kept; the next script on the same epoch runs), the row cap (KILL for plain reads, drained when
// the read may call a writing function), the Protected mode gate, the server-verified tracking
// of a user transaction after statements that may commit implicitly, and EXPLAIN ANALYZE of a
// write under read-only. Opt-in (`.requiresMySQL`, `.requiresMySQLTLS`). Tables use `mgr_`.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLManagerTests {
  typealias Server = MySQLSessionTests.Server

  private let open = ProtectionPolicy(protectionLevel: .none)
  private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - Connect and brakes

  @Test("Connect over plain TCP", .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func connectPlain(server: Server) async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(server))
    let result = try await manager.execute(userSQL: "SELECT 1 AS one", policy: open)
    #expect(result.rows == [[.int(1)]])
    #expect(await manager.isConnected)
    await manager.disconnect()
  }

  @Test(
    "Connect with verified TLS, and with mTLS; KILL QUERY reuses the TLS after connect",
    .requiresMySQL, .requiresMySQLTLS, .timeLimit(.minutes(1)))
  func connectTLSAndMutualTLS() async throws {
    var tls = Self.config(.mysql)
    tls.sslMode = .verifyFull
    tls.clientCertificate = ClientCertificateInfo(
      subject: "dblore test client", expiry: nil, hasCA: true)
    let manager = DatabaseConnectionManager()
    try await MySQLSessionTests.withMaterial(for: tls) {
      try await manager.connect(config: tls)
    }
    let cipher = try await manager.execute(
      userSQL: "SHOW SESSION STATUS LIKE 'Ssl_cipher'", policy: open)
    #expect(cipher.rows.count == 1)
    #expect(cipher.rows.first?.last != .string(""))
    await manager.disconnect()

    var mutual = tls
    mutual.username = TestMySQLDatabase.x509Username
    mutual.password = TestMySQLDatabase.x509Password
    let x509 = DatabaseConnectionManager()
    try await MySQLSessionTests.withMaterial(for: mutual) {
      try await x509.connect(config: mutual)
    }
    let user = try await x509.execute(userSQL: "SELECT CURRENT_USER()", policy: open)
    guard case .string(let name) = user.rows.first?.first else {
      Issue.record("no CURRENT_USER()")
      await x509.disconnect()
      return
    }
    #expect(name.hasPrefix("dblore_x509@"))
    // The client certificate is no longer in scope: the control connection reuses the TLS.
    try await Self.cancelSleep(on: x509, policy: open)
    #expect(try await x509.execute(userSQL: "SELECT 2", policy: open).rows == [[.int(2)]])
    await x509.disconnect()
  }

  @Test(
    "Connect applies the configured brakes", .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func brakesApplied(server: Server) async throws {
    var config = Self.config(server)
    config.statementTimeoutSeconds = 7
    config.lockTimeoutSeconds = 3
    config.idleInTransactionTimeoutSeconds = 120
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    let timeout =
      server == .mysql
      ? "@@SESSION.max_execution_time" : "CAST(@@SESSION.max_statement_time AS SIGNED)"
    let values = try await manager.executeInternal(
      """
      SELECT \(timeout), @@SESSION.innodb_lock_wait_timeout, @@SESSION.lock_wait_timeout,
        @@SESSION.wait_timeout
      """)
    let expected: CellValue = server == .mysql ? .int(7000) : .int(7)
    #expect(values.rows == [[expected, .int(3), .int(3), .int(120)]])
    await manager.disconnect()
  }

  // MARK: - KILL QUERY

  @Test(
    "Cancel keeps session, epoch and app transaction; the next script on the epoch runs",
    .requiresMySQL, .timeLimit(.minutes(1)),
    arguments: [Server.mysql, .mariadb])
  func cancelKeepsAppTransaction(server: Server) async throws {
    let table = "mgr_cancel"
    try await withTable(table, server, protectedMode: true) { manager, observer in
      let epoch = await manager.connectionEpoch

      // Cancel, then Rollback: the UPDATE was still pending.
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: protected)
      try await Self.cancelSleep(on: manager, policy: protected)
      #expect(await manager.connectionEpoch == epoch)
      #expect(await manager.transactionSnapshot().pending.count == 1)
      // A later script on the same epoch runs, inside the app transaction.
      let inside = try await manager.execute(
        userSQL: "SELECT v FROM \(table) WHERE id = 1", policy: protected)
      #expect(inside.rows == [[.int(20)]])
      #expect(try await Self.value(observer, table) == .int(10))
      try await manager.rollbackAppTransaction()
      #expect(try await Self.value(observer, table) == .int(10))

      // A second cancel on the same epoch, then Commit.
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 30 WHERE id = 1", policy: protected)
      try await Self.cancelSleep(on: manager, policy: protected)
      #expect(await manager.connectionEpoch == epoch)
      #expect(await manager.transactionSnapshot().pending.count == 1)
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
      #expect(await manager.transactionSnapshot().isIdle)
      #expect(try await Self.value(observer, table) == .int(30))
    }
  }

  // MARK: - Row cap

  @Test(
    "A read left at the cap is killed: the session, epoch and app transaction stay",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func cappedReadKeepsSession(server: Server) async throws {
    let table = "mgr_cap"
    try await withTable(table, server, protectedMode: true) { manager, observer in
      _ = try await observer.executeInternal(
        "INSERT INTO \(table) SELECT seq.id, 0 FROM (\(Self.hundredRows)) seq WHERE seq.id > 1")
      let epoch = await manager.connectionEpoch
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: protected)

      let start = ContinuousClock.now
      // 1,000,000 rows, no function call: KILL QUERY at the cap.
      let capped = try await manager.execute(
        userSQL: "SELECT a.id FROM \(table) a CROSS JOIN \(table) b CROSS JOIN \(table) c",
        policy: protected, maxRows: 10)
      #expect(capped.rows.count == 10)
      #expect(capped.truncated)
      #expect(capped.sessionReset == false)
      let next = try await manager.execute(
        userSQL: "SELECT v FROM \(table) WHERE id = 1", policy: protected)
      #expect(next.rows == [[.int(20)]])
      #expect(ContinuousClock.now - start < .seconds(5))
      #expect(await manager.connectionEpoch == epoch)
      #expect(await manager.transactionSnapshot().pending.count == 1)
      try await manager.rollbackAppTransaction()
    }
  }

  @Test(
    "A read that calls a writing function is read to the end at the cap, not killed",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func functionReadAtCapDrains(server: Server) async throws {
    let table = "mgr_func_log"
    let function = "\(TestMySQLDatabase.database).mgr_log_row"
    // Root, and DETERMINISTIC: binary logging is on in MySQL 8.4 (error 1418 otherwise).
    try await MySQLSessionTests.withSession(Self.rootConfig(server)) { root in
      _ = try await root.command("DROP FUNCTION IF EXISTS \(function)", binds: [])
      _ = try await root.command(
        """
        CREATE FUNCTION \(function)(n INT) RETURNS INT DETERMINISTIC MODIFIES SQL DATA
        BEGIN
          INSERT INTO \(TestMySQLDatabase.database).\(table) VALUES (n, n);
          DO SLEEP(0.005);
          RETURN n;
        END
        """, binds: [])
      do {
        try await withTable(table, server, protectedMode: false) { manager, observer in
          _ = try await observer.executeInternal("DELETE FROM \(table)")
          // Wide rows, so the server sends them while the statement still runs.
          let capped = try await manager.execute(
            userSQL:
              "SELECT mgr_log_row(seq.id), REPEAT('x', 4000) FROM (\(Self.hundredRows)) seq",
            policy: open, maxRows: 10)
          #expect(capped.rows.count == 10)
          #expect(capped.truncated)
          // Autocommit: every row the function wrote is committed (a KILL rolls them back).
          let count = try await observer.executeInternal("SELECT COUNT(*) FROM \(table)")
          #expect(count.rows == [[.int(100)]])
        }
      } catch {
        _ = try? await root.command("DROP FUNCTION IF EXISTS \(function)", binds: [])
        throw error
      }
      _ = try await root.command("DROP FUNCTION IF EXISTS \(function)", binds: [])
    }
  }

  // MARK: - Gate

  @Test(
    "Protected mode refuses MySQL DDL with the implicit-commit message, also with DML pending",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func gateRefusesDDLUnderProtectedMode(server: Server) async throws {
    let table = "mgr_gate"
    try await withTable(table, server, protectedMode: true) { manager, observer in
      _ = try await observer.executeInternal("DROP TABLE IF EXISTS mgr_gate_new")

      try await Self.expectImplicitCommitRefusal(manager, "CREATE TABLE mgr_gate_new (id INT)")
      #expect(await manager.transactionSnapshot().isIdle)

      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: protected)
      try await Self.expectImplicitCommitRefusal(manager, "CREATE TABLE mgr_gate_new (id INT)")
      try await Self.expectImplicitCommitRefusal(manager, "ALTER TABLE \(table) ADD COLUMN w INT")
      #expect(await manager.transactionSnapshot().pending.count == 1)
      #expect(try await Self.value(observer, table) == .int(10))
      try await manager.rollbackAppTransaction()
      #expect(try await Self.value(observer, table) == .int(10))
      let created = try await observer.executeInternal(
        """
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = 'mgr_gate_new'
        """)
      #expect(created.rows == [[.int(0)]])
    }
  }

  @Test(
    "EXPLAIN ANALYZE of a DELETE is refused on a read-only connection",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func explainAnalyzeOfDeleteRefusedUnderReadOnly(server: Server) async throws {
    let table = "mgr_explain"
    try await withTable(table, server, protectedMode: false, level: .readOnly) {
      manager, observer in
      for sql in ["EXPLAIN ANALYZE DELETE FROM \(table)", "ANALYZE DELETE FROM \(table)"] {
        do {
          _ = try await manager.execute(userSQL: sql, policy: open)
          Issue.record("\(sql) ran on a read-only connection")
        } catch DatabaseError.blockedByProtection(_, _, let reason) {
          #expect(reason.contains("read-only"), "\(reason)")
        }
      }
      #expect(try await Self.value(observer, table) == .int(10))
    }
  }

  // MARK: - Implicit commits with Protected mode off

  @Test(
    "Protected off: user transaction tracking follows the server after implicit commits",
    .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func implicitCommitTracking(server: Server) async throws {
    let table = "mgr_track"
    try await withTable(table, server, protectedMode: false) { manager, observer in
      _ = try await observer.executeInternal("DROP TABLE IF EXISTS mgr_track_ddl")
      _ = try await observer.executeInternal("DROP TABLE IF EXISTS mgr_track_inner")
      _ = try await observer.executeInternal("DROP PROCEDURE IF EXISTS mgr_noop")
      _ = try await observer.executeInternal("DROP PROCEDURE IF EXISTS mgr_commits")
      _ = try await observer.executeInternal("CREATE PROCEDURE mgr_noop() DO 0")
      _ = try await observer.executeInternal(
        "CREATE PROCEDURE mgr_commits() CREATE TABLE mgr_track_inner (id INT)")

      func run(_ sql: String) async throws {
        _ = try await manager.execute(userSQL: sql, policy: open)
      }
      func tracked() async -> Bool { await manager.runningStatementStatus().userTxOpen }

      // CALL that does not commit, and an unrecognized statement: still open on the server.
      try await run("START TRANSACTION")
      try await run("UPDATE \(table) SET v = 20 WHERE id = 1")
      try await run("CALL mgr_noop()")
      #expect(await tracked())
      try await run("SELECT 1 /*!, 2 */")
      #expect(await tracked())
      #expect(try await Self.value(observer, table) == .int(10))
      if server == .mariadb {
        let state = try await manager.execute(userSQL: "SELECT @@in_transaction", policy: open)
        #expect(state.rows == [[.int(1)]])
      }

      // CREATE TABLE commits it.
      try await run("CREATE TABLE mgr_track_ddl (id INT)")
      #expect(await tracked() == false)
      #expect(try await Self.value(observer, table) == .int(20))

      // A CALL whose body commits: closed, as the server says.
      try await run("START TRANSACTION")
      try await run("UPDATE \(table) SET v = 30 WHERE id = 1")
      try await run("CALL mgr_commits()")
      #expect(await tracked() == false)
      #expect(try await Self.value(observer, table) == .int(30))

      // A failed DDL, and SET autocommit: tracking matches what the server committed.
      for (index, sql) in ["CREATE TABLE mgr_track_ddl (id INT)", "SET autocommit = 1"]
        .enumerated()
      {
        let v = 40 + index
        try await run("START TRANSACTION")
        try await run("UPDATE \(table) SET v = \(v) WHERE id = 1")
        _ = try? await manager.execute(userSQL: sql, policy: open)
        let committed = try await Self.value(observer, table) == .int(v)
        #expect(await tracked() == !committed, "\(sql)")
        if await tracked() { try await run("ROLLBACK") }
      }
      _ = try await observer.executeInternal("DROP TABLE IF EXISTS mgr_track_ddl")
      _ = try await observer.executeInternal("DROP TABLE IF EXISTS mgr_track_inner")
      _ = try await observer.executeInternal("DROP PROCEDURE IF EXISTS mgr_noop")
      _ = try await observer.executeInternal("DROP PROCEDURE IF EXISTS mgr_commits")
    }
  }

  // MARK: - Helpers

  /// SELECT 1 AS id UNION ALL ... SELECT 100: a derived table of ids 1...100.
  static let hundredRows = (1...100).map { "SELECT \($0) AS id" }.joined(separator: " UNION ALL ")

  static func config(
    _ server: Server, protectedMode: Bool = false, level: ConnectionProtectionLevel = .none
  ) -> ConnectionConfig {
    var config = MySQLSessionTests.config(port: server.port)
    config.protectedMode = protectedMode
    config.protectionLevel = level
    return config
  }

  static func rootConfig(_ server: Server) -> ConnectionConfig {
    MySQLSessionTests.config(port: server.port, username: "root", password: "dblore123")
  }

  /// Runs `body` with `manager` (per `protectedMode` / `level`) and an unprotected observer;
  /// `table (id INT PRIMARY KEY, v INT)` holds (1, 10). Both disconnect and `table` is dropped
  /// on every path.
  private func withTable(
    _ table: String, _ server: Server, protectedMode: Bool,
    level: ConnectionProtectionLevel = .none,
    _ body: (DatabaseConnectionManager, DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let observer = DatabaseConnectionManager()
    let manager = DatabaseConnectionManager()
    do {
      try await observer.connect(config: Self.config(server))
      _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
      _ = try await observer.executeInternal(
        "CREATE TABLE \(table) (id INT PRIMARY KEY, v INT)")
      _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")
      try await manager.connect(
        config: Self.config(server, protectedMode: protectedMode, level: level))
      try await body(manager, observer)
    } catch {
      await Self.tearDown(table, manager, observer)
      throw error
    }
    await Self.tearDown(table, manager, observer)
  }

  private static func tearDown(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async {
    try? await manager.rollbackAppTransaction()
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  private static func value(
    _ manager: DatabaseConnectionManager, _ table: String
  ) async throws -> CellValue? {
    try await manager.executeInternal("SELECT v FROM \(table) WHERE id = 1").rows.first?.first
  }

  /// Runs SELECT SLEEP(10), cancels it once it runs, and expects `.queryCancelled` within 3 s.
  private static func cancelSleep(
    on manager: DatabaseConnectionManager, policy: ProtectionPolicy
  ) async throws {
    let sleeping = Task {
      try await manager.execute(userSQL: "SELECT SLEEP(10)", policy: policy)
    }
    var status = await manager.runningStatementStatus()
    while !status.inFlight {
      try await Task.sleep(for: .milliseconds(10))
      status = await manager.runningStatementStatus()
    }
    try await Task.sleep(for: .milliseconds(300))
    let start = ContinuousClock.now
    // Repeat: a KILL sent before the statement reached the server stops nothing. A repeat may
    // find the statement already gone (`.nothingRunning`).
    var first = true
    while await manager.runningStatementStatus().inFlight {
      let outcome = await manager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      if first { #expect(outcome == .cancelled) }
      first = false
      try await Task.sleep(for: .milliseconds(200))
    }
    let error = await #expect(throws: DatabaseError.self) { try await sleeping.value }
    guard case .queryCancelled = error else {
      Issue.record("Expected queryCancelled, got \(String(describing: error))")
      return
    }
    #expect(ContinuousClock.now - start < .seconds(3))
  }

  private static func expectImplicitCommitRefusal(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws {
    do {
      _ = try await manager.execute(
        userSQL: sql, policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true))
      Issue.record("\(sql) ran under Protected mode")
    } catch DatabaseError.blockedByProtection(_, _, let reason) {
      #expect(reason.contains("commits implicitly on MySQL"), "\(reason)")
    }
  }
}
