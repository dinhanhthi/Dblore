// DatabaseConnectionManager+Session.swift
// Session-brake SQL. PostgresSession sends it; this forwarder stays so tests can read
// the exact statements.

import Foundation

extension DatabaseConnectionManager {
  /// The SQL sent after every connect. Only clamped integers are interpolated.
  nonisolated static func brakeStatements(for config: ConnectionConfig) -> [String] {
    PostgresSession.brakeStatements(for: config)
  }
}
