// DatabaseConnectionManager+Session.swift
// Session brakes applied after every connect: server-side timeouts and application_name.
// App-owned SQL, sent directly on the connection (never through the user gate).

import Foundation
import Logging
import PostgresNIO

/// Allowed ranges and defaults for the per-connection safety settings.
/// Shared by the SQL builder and the connection form so both clamp identically.
nonisolated enum SessionBrakeLimits {
  static let statementTimeoutRange = 1...86400
  static let lockTimeoutRange = 1...3600
  static let idleTimeoutRange = 1...86400
  static let rowCapRange = 100...100_000

  static let defaultStatementTimeout = 60
  static let defaultLockTimeout = 5
  static let defaultIdleTimeout = 600

  /// Non-positive → `defaultValue` (0 would disable the brake); otherwise clamp to `range`.
  static func clamp(_ value: Int, to range: ClosedRange<Int>, default defaultValue: Int) -> Int {
    value <= 0 ? defaultValue : min(max(value, range.lowerBound), range.upperBound)
  }

  static func clampStatementTimeout(_ value: Int) -> Int {
    clamp(value, to: statementTimeoutRange, default: defaultStatementTimeout)
  }

  static func clampLockTimeout(_ value: Int) -> Int {
    clamp(value, to: lockTimeoutRange, default: defaultLockTimeout)
  }

  static func clampIdleTimeout(_ value: Int) -> Int {
    clamp(value, to: idleTimeoutRange, default: defaultIdleTimeout)
  }

  /// `nil` or non-positive → `nil` (use the global setting); otherwise clamp to `rowCapRange`.
  static func clampRowCap(_ value: Int?) -> Int? {
    guard let value, value > 0 else { return nil }
    return min(max(value, rowCapRange.lowerBound), rowCapRange.upperBound)
  }
}

extension DatabaseConnectionManager {
  /// The SQL sent after every connect. Only clamped integers are interpolated.
  nonisolated static func brakeStatements(for config: ConnectionConfig) -> [String] {
    let statement = SessionBrakeLimits.clampStatementTimeout(config.statementTimeoutSeconds)
    let lock = SessionBrakeLimits.clampLockTimeout(config.lockTimeoutSeconds)
    let idle = SessionBrakeLimits.clampIdleTimeout(config.idleInTransactionTimeoutSeconds)
    return [
      "SET statement_timeout = '\(statement)s'",
      "SET lock_timeout = '\(lock)s'",
      "SET idle_in_transaction_session_timeout = '\(idle)s'",
      "SET application_name = 'SQLNotebook'",
    ]
  }

  /// Apply the session brakes on a connection that is not published yet (`connect`), each
  /// statement raced against its closure (`watch`).
  /// - Throws: `DatabaseError.connectionFailed` if any statement fails or the connection closes.
  func applySessionBrakes(
    on connection: PostgresConnection, watch: ConnectionCloseWatch, config: ConnectionConfig
  ) async throws {
    for sql in Self.brakeStatements(for: config) {
      do {
        _ = try await watch.run {
          try await connection.query(
            PostgresQuery(unsafeSQL: sql), logger: Logger(label: "sqlnotebook.session")
          ).get()
        }
      } catch let error as PSQLError {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): \(formatPostgresError(error))")
      } catch is ConnectionClosedError {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): the server closed the connection")
      } catch {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): \(error.localizedDescription)")
      }
    }
  }

  /// Best effort, after the brakes: the server checks every second whether the client is still
  /// connected while a statement runs, so closing the connection (Cancel) stops even a statement
  /// that sends nothing (`pg_sleep`, a long sort). PostgreSQL 14+ on platforms that support
  /// it; elsewhere the error is only logged (Cancel then still frees the app at once, and the
  /// server stops at its next write or at `statement_timeout`).
  nonisolated static let disconnectCheckSQL = "SET client_connection_check_interval = '1s'"

  func applyDisconnectCheck(on connection: PostgresConnection, watch: ConnectionCloseWatch) async {
    do {
      _ = try await watch.run {
        try await connection.query(
          PostgresQuery(unsafeSQL: Self.disconnectCheckSQL),
          logger: Logger(label: "sqlnotebook.session")
        ).get()
      }
    } catch {
      await AppLogger.shared.warning(
        "client_connection_check_interval not applied (server work continues after Cancel "
          + "until its next write): \(String(describing: error))", category: "Database")
    }
  }
}
