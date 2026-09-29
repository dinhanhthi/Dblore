// DatabaseSessionBrakeTests.swift
// Session brakes (S7) against the docker test database (TEST_DB_* env, port 5435 in CI/autopilot)

import Foundation
import PostgresNIO
import Testing

@testable import Dblore

@Suite("Session Brakes - Integration (Requires PostgreSQL)")
struct DatabaseSessionBrakeTests {
  static func testConfig(statementTimeoutSeconds: Int = 60) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      statementTimeoutSeconds: statementTimeoutSeconds
    )
  }

  private func show(_ manager: DatabaseConnectionManager, _ setting: String) async throws -> String?
  {
    let value = try await manager.executeInternal("SHOW \(setting)").rows.first?.first
    if case .string(let text) = value { return text }
    return nil
  }

  private func expectDefaultBrakes(_ manager: DatabaseConnectionManager) async throws {
    #expect(try await show(manager, "statement_timeout") == "1min")
    #expect(try await show(manager, "lock_timeout") == "5s")
    #expect(try await show(manager, "idle_in_transaction_session_timeout") == "10min")
    #expect(try await show(manager, "application_name") == "Dblore")
  }

  @Test("Default config: brakes and application_name are set after connect")
  func defaultBrakes() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.testConfig())
    defer { Task { await manager.disconnect() } }
    try await expectDefaultBrakes(manager)
  }

  @Test("statementTimeoutSeconds = 1: pg_sleep(2) is cancelled with SQLSTATE 57014")
  func statementTimeoutCancelsQuery() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.testConfig(statementTimeoutSeconds: 1))
    defer { Task { await manager.disconnect() } }
    #expect(try await show(manager, "statement_timeout") == "1s")

    let connection = try #require(await manager._connection)
    var sqlState: String?
    do {
      _ = try await connection.query(
        PostgresQuery(unsafeSQL: "SELECT pg_sleep(2)"), logger: Logger(label: "test.brakes")
      ).get()
    } catch let error as PSQLError {
      sqlState = error.serverInfo?[.sqlState]
    }
    #expect(sqlState == "57014")
  }

  @Test("Brakes are applied again after disconnect + reconnect")
  func brakesSurviveReconnect() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.testConfig())
    await manager.disconnect()
    try await manager.connect(config: Self.testConfig())
    defer { Task { await manager.disconnect() } }
    try await expectDefaultBrakes(manager)

    // Reconnecting while connected (connect() disconnects first) also re-applies them
    try await manager.connect(config: Self.testConfig(statementTimeoutSeconds: 1))
    #expect(try await show(manager, "statement_timeout") == "1s")
    #expect(try await show(manager, "application_name") == "Dblore")
  }
}
