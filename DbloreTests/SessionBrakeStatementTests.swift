// SessionBrakeStatementTests.swift
// Pure tests for the session brake SQL sent after every connect (S7), and the brakes a flavor
// does not support (Redshift: statement_timeout only) at open, after an app BEGIN and in a dump.
// One check runs a session against the loopback wire stand-in (`FakePostgresServer`).

import Testing

@testable import Dblore

struct SessionBrakeStatementTests {
  private func statements(
    statement: Int = 60, lock: Int = 5, idle: Int = 600
  ) -> [String] {
    DatabaseConnectionManager.brakeStatements(
      for: ConnectionConfig(
        statementTimeoutSeconds: statement, lockTimeoutSeconds: lock,
        idleInTransactionTimeoutSeconds: idle))
  }

  @Test("Default config produces the exact brake SQL in order")
  func defaults() {
    #expect(
      DatabaseConnectionManager.brakeStatements(for: ConnectionConfig()) == [
        "SET statement_timeout = '60s'",
        "SET lock_timeout = '5s'",
        "SET idle_in_transaction_session_timeout = '600s'",
        "SET application_name = 'Dblore'",
      ])
  }

  @Test(
    "Zero or negative values fall back to the defaults (never disable a brake)",
    arguments: [0, -1, Int.min])
  func nonPositiveFallsBackToDefault(_ value: Int) {
    #expect(
      statements(statement: value, lock: value, idle: value) == [
        "SET statement_timeout = '60s'",
        "SET lock_timeout = '5s'",
        "SET idle_in_transaction_session_timeout = '600s'",
        "SET application_name = 'Dblore'",
      ])
  }

  @Test("Huge values are clamped to the maximum", arguments: [86401, 1_000_000, Int.max])
  func hugeValuesClamped(_ value: Int) {
    #expect(
      statements(statement: value, lock: value, idle: value) == [
        "SET statement_timeout = '86400s'",
        "SET lock_timeout = '3600s'",
        "SET idle_in_transaction_session_timeout = '86400s'",
        "SET application_name = 'Dblore'",
      ])
  }

  @Test("Clamp helper keeps UI and SQL on the same ranges")
  func clampHelper() {
    #expect(SessionBrakeLimits.clampStatementTimeout(0) == 60)
    #expect(SessionBrakeLimits.clampStatementTimeout(90000) == 86400)
    #expect(SessionBrakeLimits.clampLockTimeout(-5) == 5)
    #expect(SessionBrakeLimits.clampLockTimeout(4000) == 3600)
    #expect(SessionBrakeLimits.clampIdleTimeout(0) == 600)
    #expect(SessionBrakeLimits.clampIdleTimeout(120) == 120)
    #expect(SessionBrakeLimits.clampRowCap(nil) == nil)
    #expect(SessionBrakeLimits.clampRowCap(0) == nil)
    #expect(SessionBrakeLimits.clampRowCap(5) == 100)
    #expect(SessionBrakeLimits.clampRowCap(200_000) == 100_000)
  }

  // MARK: - Flavors

  @MainActor private static func redshift() -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    config.flavor = .redshift
    return config
  }

  private static let redshiftVersion =
    "PostgreSQL 8.0.2 on i686-pc-linux-gnu, compiled by GCC 3.4.2 20041017 (Red Hat 3.4.2-6.fc3), "
    + "Redshift 1.0.12345"
  private static let postgresVersion =
    "PostgreSQL 16.4 on aarch64-apple-darwin23.0.0, compiled by Apple clang version 15.0.0, 64-bit"

  @Test("Only a server that reports Redshift drops the brakes Redshift refuses")
  func brakeFlavorIsVerified() {
    #expect(
      PostgresSession.brakeFlavor(configured: .redshift, serverVersion: Self.redshiftVersion)
        == .redshift)
    #expect(
      PostgresSession.brakeFlavor(configured: .redshift, serverVersion: Self.postgresVersion) == nil
    )
    #expect(PostgresSession.brakeFlavor(configured: .redshift, serverVersion: nil) == nil)
  }

  /// A Redshift flavor sends the brakes its server's `version()` allows: all on PostgreSQL
  @Test(
    "A Redshift-flavored session sends the brakes its server's version() allows",
    .timeLimit(.minutes(1)), arguments: [false, true])
  @MainActor func sessionBrakesFollowServerVersion(reportsRedshift: Bool) async throws {
    let server = FakePostgresServer(
      pid: 7, backendStart: "2026-11-03 10:15:42+01", answer: .cancelled,
      version: reportsRedshift ? Self.redshiftVersion : Self.postgresVersion)
    var config = Self.redshift()
    config.host = "127.0.0.1"
    config.port = try server.start()
    defer { server.stop() }
    let session = PostgresSession(config: config)
    try await session.open()
    do {
      try await session.applySessionSettings(
        statementTimeoutSeconds: 60, lockTimeoutSeconds: 5, idleTimeoutSeconds: 600)
    } catch {
      Issue.record(error)
    }
    await session.close()
    let sent = server.receivedStatements
    #expect(sent.contains("SET statement_timeout = '60s'"))
    #expect(sent.contains("SET lock_timeout = '5s'") != reportsRedshift)
    #expect(sent.contains("SET idle_in_transaction_session_timeout = '600s'") != reportsRedshift)
  }

  @Test("Verified Redshift: open sends no lock_timeout or idle-in-transaction setting")
  @MainActor func redshiftOpen() {
    let verified = PostgresSession.brakeFlavor(
      configured: .redshift, serverVersion: Self.redshiftVersion)
    #expect(
      DatabaseConnectionManager.brakeStatements(for: Self.redshift(), brakeFlavor: verified) == [
        "SET statement_timeout = '60s'", "SET application_name = 'Dblore'",
      ])
  }

  @Test("Verified Redshift: the app BEGIN is not followed by an idle-in-transaction SET")
  @MainActor func redshiftAppBegin() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: Self.redshift())
    let session = try #require(factory.sessions.first)
    session.brakeFlavor = .redshift
    try await manager.beginAppTransaction(caller: nil)
    #expect(session.statements == ["BEGIN"])
  }

  @Test("Verified Redshift: the dump lifts statement_timeout only")
  func redshiftDump() async throws {
    let session = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: [], slowQueries: false)
    session.brakeFlavor = .redshift
    _ = try await DatabaseConnectionManager.runDumpSnapshot(
      on: session, databaseType: .postgresql, serverInfo: nil
    ) { _ in 0 }
    #expect(session.statements.contains("SET LOCAL statement_timeout = 0"))
    #expect(!session.statements.contains { $0.contains("lock_timeout") })
    #expect(!session.statements.contains { $0.contains("idle_in_transaction") })
  }

  @Test("A Redshift flavor the server does not confirm keeps every brake")
  @MainActor func unverifiedRedshiftKeepsBrakes() async throws {
    let unverified = PostgresSession.brakeFlavor(
      configured: .redshift, serverVersion: Self.postgresVersion)
    #expect(
      DatabaseConnectionManager.brakeStatements(for: Self.redshift(), brakeFlavor: unverified)
        == DatabaseConnectionManager.brakeStatements(for: ConnectionConfig()))
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: Self.redshift())
    let session = try #require(factory.sessions.first)
    _ = try await manager.withDumpSnapshot { _ in 0 }
    #expect(session.statements.contains("SET LOCAL lock_timeout = 0"))
    #expect(session.statements.contains("SET LOCAL idle_in_transaction_session_timeout = 0"))
    try await manager.beginAppTransaction(caller: nil)
    #expect(
      session.statements.suffix(2) == ["BEGIN", DatabaseConnectionManager.suspendIdleTimeoutSQL])
  }
}
