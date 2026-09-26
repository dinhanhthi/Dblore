// DatabaseConnectionManager+Gate.swift
// Execution gate: every user SQL is classified and checked against the protection policy
// before any statement is sent. App-owned SQL uses `executeInternal`.

import Foundation
import Logging
import PostgresNIO

/// Outcome of checking a classified script against a `ProtectionPolicy`.
nonisolated enum GateDecision: Sendable, Equatable {
  case allowed
  /// `statementIndex` is the 0-based index of the first violating statement
  case blocked(statementIndex: Int, kind: StatementKind, reason: String)
}

extension DatabaseConnectionManager {
  // MARK: - Gated entry points (user SQL)

  /// Execute user SQL (one or more statements) and return the combined result.
  /// Throws `DatabaseError.blockedByProtection` before anything is sent if ANY statement
  /// violates `policy`.
  func execute(
    userSQL: String, policy: ProtectionPolicy, maxRows: Int = defaultMaxFetchRows
  ) async throws -> QueryResult {
    try authorize(userSQL, policy: policy)
    return try await executeInternal(userSQL, maxRows: maxRows)
  }

  /// Execute user SQL and return one result per statement.
  /// Throws `DatabaseError.blockedByProtection` before anything is sent if ANY statement
  /// violates `policy`.
  func executeDetailed(
    userSQL: String, policy: ProtectionPolicy, maxRows: Int = defaultMaxFetchRows
  ) async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval) {
    try authorize(userSQL, policy: policy)
    return try await executeInternalStatementsDetailed(userSQL, maxRows: maxRows)
  }

  /// Send an inline grid edit (app-built UPDATE, values as bind parameters) and return the
  /// number of rows the server reports as updated (command tag, not result rows).
  /// Throws `DatabaseError.notEditable` before anything is sent if `connectionEpoch` (of the
  /// edit target) is not the current connection's, and `DatabaseError.blockedByProtection` if
  /// `policy` forbids it.
  func executeGatedUpdate(
    _ statement: CellUpdateStatement, policy: ProtectionPolicy, connectionEpoch epoch: UInt64
  )
    async throws -> Int
  {
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    try authorize(statement.sql, policy: policy)
    guard let connection = _connection else { throw DatabaseError.notConnected }
    let startTime = Date()
    do {
      let result = try await connection.query(
        PostgresQuery(unsafeSQL: statement.sql, binds: statement.bindings),
        logger: Logger(label: "sqlnotebook.update")
      ).get()
      return result.metadata.rows ?? 0
    } catch let error as PSQLError {
      throw DatabaseError.queryFailed(
        formatPostgresError(error, query: statement.sql), Date().timeIntervalSince(startTime))
    } catch {
      throw DatabaseError.queryFailed(
        error.localizedDescription, Date().timeIntervalSince(startTime))
    }
  }

  // MARK: - Gate

  /// Classify every statement of `sql` and throw if the stricter of `policy` and the connected
  /// config's protection blocks any of them (a caller can never weaken the connection).
  private func authorize(_ sql: String, policy: ProtectionPolicy) throws {
    let decision = Self.evaluate(
      SQLStatementClassifier.classify(sql), policy: policy.stricter(connectedPolicy))
    if case .blocked(let index, let kind, let reason) = decision {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
  }

  /// Pure policy check: the first statement the policy forbids, or `.allowed`.
  /// - `.readOnly`: only read-only-safe statements (reads, plain EXPLAIN of a known statement).
  /// - `.schemaOnly`: no DDL, non-transactional, utility, unknown or table-creating statements
  ///   (also under EXPLAIN ANALYZE); DML, SET and transaction control are allowed.
  /// - `.none`: everything (Safe Mode confirmation lives in the ViewModel).
  nonisolated static func evaluate(
    _ statements: [ClassifiedStatement], policy: ProtectionPolicy
  ) -> GateDecision {
    for (index, statement) in statements.enumerated() {
      if let reason = violation(statement, level: policy.protectionLevel) {
        return .blocked(statementIndex: index, kind: statement.kind, reason: reason)
      }
    }
    return .allowed
  }

  private nonisolated static func violation(
    _ statement: ClassifiedStatement, level: ConnectionProtectionLevel
  ) -> String? {
    switch level {
    case .none:
      return nil
    case .readOnly:
      if statement.isReadOnlySafe && !statement.resetsSessionBrakes
        && !statement.changesPrivileges
      {
        return nil
      }
      return "\(describe(statement.kind)) is not allowed on a read-only connection"
    case .schemaOnly:
      let kind = SQLStatementClassifier.effectiveKind(statement.kind)
      let what: String
      if kind == .ddl {
        what = "Schema change"
      } else if kind == .utility || kind == .unknown {
        what = "\(describe(statement.kind)) (its effects cannot be verified)"
      } else if statement.nonTransactional {
        what = "Statement that cannot run in a transaction"
      } else if statement.createsTable {
        what = "SELECT ... INTO (creates a table)"
      } else {
        return nil
      }
      return "\(what) is blocked on a schema-protected connection"
    }
  }

  nonisolated static func describe(_ kind: StatementKind) -> String {
    switch kind {
    case .read: "Read"
    case .dml: "Data modification"
    case .ddl: "Schema change"
    case .tcl: "Transaction control"
    case .sessionSet: "Session setting change (SET/RESET)"
    case .utility: "Utility command (DO, CALL, COPY, VACUUM, GRANT, ...)"
    case .explain(let inner, analyze: true):
      "EXPLAIN ANALYZE (runs the statement)"
        + (inner == .unknown ? "" : " of \(describe(inner).lowercased())")
    case .explain(let inner, analyze: false):
      inner == .unknown ? "EXPLAIN of an unrecognized statement" : "EXPLAIN (plan only)"
    case .unknown: "Unrecognized statement"
    }
  }
}
