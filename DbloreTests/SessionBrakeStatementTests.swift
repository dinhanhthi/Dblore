// SessionBrakeStatementTests.swift
// Pure tests for the session brake SQL sent after every connect (S7)

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

  @Test("Custom values in range are used as-is")
  func customValues() {
    #expect(
      statements(statement: 1, lock: 3600, idle: 86400) == [
        "SET statement_timeout = '1s'",
        "SET lock_timeout = '3600s'",
        "SET idle_in_transaction_session_timeout = '86400s'",
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
}
